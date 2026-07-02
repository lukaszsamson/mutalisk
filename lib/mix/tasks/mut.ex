defmodule Mix.Tasks.Mut do
  @shortdoc "Run mutation testing against the current Mix project."
  @moduledoc """
  Runs mutation testing.

  ## Options

    - `--files "PATTERN"` — Only mutate files matching glob pattern. Quote
      globs so your shell does not expand them first. Repeat the flag or use
      comma-separated patterns to mutate several paths.
    - `--mutators NAMES` — Comma-separated mutator name list
    - `--enable TARGETS` — Comma-separated enabled targets. Defaults:
      `dispatch`, `guard`, `env_walker` (only
      AtomLiteral active; pass it explicitly to run
      all env-walker literals), `pattern_shape`.
      Opt-in: `module_attribute`, `body_literal`,
      `pattern_literal`, `variable`, `conditional`,
      `statement_delete`, `clause_delete`,
      `guard_boolean`, `pipeline_drop`,
      `map_update_drop`, `receive_timeout`. Passing
      --enable selects the default selectable mutator
      set gated by the listed targets. Note: an opt-in
      mutator selected via `--mutators` ALSO needs its
      target enabled, and a few experimental mutators
      require `--mutators` explicitly (see docs/MUTATORS.md).
    - `--fail-at SCORE` — Mutation score threshold; exit 1 below
      (default: 80)
    - `--reporters NAMES` — Comma-separated: `terminal`, `stryker-json`
      (default: both), `html`, `github-actions`
      (opt-in)
    - `--output-path PATH` — Report output path (default:
      `stryker.report.json`). Absolute paths are honored;
      relative paths are under the project root. The
      `html` reporter writes the same path with a
      `.html` extension.
    - `--concurrency N` — Worker pool size for parallel mutant execution.
      Default: min(schedulers_online, 4). Use
      `--concurrency 1` for sequential execution. Explicit
      values are bounded to avoid pathological sandbox
      startup/teardown costs.
    - `--max-mutants N` — Cap total mutants (stable-id sorted sample if
      exceeded). Caps EXECUTION only — it is applied
      after planning and coverage collection, so it
      does not reduce analysis time.
    - `--debug-plan` — Dump plan JSON to plan.debug.json and exit before
      any mutant runs. It still builds the oracle and baseline plan; it is not
      a zero-cost parser-only mode.
    - `--selection MODE` — Test selection mode: `static`, `coverage`,
      `coverage_with_static_fallback` (default, since
      v1.19/M65). `static` is the fully-portable
      escape hatch — also the fast choice on
      macro-heavy/generated apps (e.g. Phoenix) where
      coverage collection is slow before it falls back.
    - `--keep-work-copy` — Skip cleanup of the run's temporary work copies on
      exit and print their retained paths (debug aid; default: false)
    - `--test-timeout-ms N` — Per-test ExUnit timeout in milliseconds.
      Default 10000. Range 1000..600000.
    - `--incremental` — Reuse verdicts from a prior run's history for
      unchanged mutants instead of re-executing them
      (opt-in; see `history_path` config). Materially
      changes execution and report interpretation.
    - `--since REF` — With `--incremental`, restrict reuse to mutants
      whose file changed since git `REF` (e.g. `HEAD~1`,
      `main`). Outside a git repo or with an unknown ref,
      reuse falls back to digest checks with a warning.

  ## Configuration

  Settings can come from three layers, lowest to highest precedence:

      .mutalisk.exs project file  <  config :mut  <  CLI flags

  A CLI flag always wins; `config :mut` overrides the file; the file is the
  base. Keys (same names in all layers): `files`, `test_paths`, `mutators`,
  `enabled_targets`, `selection`, `fail_at`, `concurrency`, `test_timeout_ms`,
  `reporters`, `output_path`, `exclude`, `max_mutants`, `since`, `incremental`,
  `history_path`, and `coverage_timeout_ms`. `exclude`, `history_path`, and
  `coverage_timeout_ms` are config-only (no CLI flag); the rest accept a CLI
  flag that overrides config. `history_path` controls where every run writes
  reusable verdict history for future `--incremental` runs. `coverage_timeout_ms`
  is a positive integer in milliseconds for each per-test-file coverage
  collection attempt; in `coverage_with_static_fallback`, timed-out files degrade
  to static selection. Run-scoped switches `debug_plan` and `keep_work_copy` are
  CLI-only.

  When `test_paths` is unset it defaults to `test/` for a single app and to
  every child app's `apps/<app>/test/` for an umbrella. Set it explicitly only
  to override that — note a bare `["test"]` finds no tests in an umbrella.

  `.mutalisk.exs` (in the project root, loaded if present) is a plain
  keyword-list term — no `Config` runtime needed:

      # .mutalisk.exs
      [
        selection: :coverage_with_static_fallback,
        fail_at: 75.0,
        concurrency: 8,
        exclude: [~r"lib/my_app_web/router.ex"]
      ]

  Or via application config:

      config :mut,
        exclude: [~r/lib\\/my_app_web\\/router.ex/],
        fail_at: 80.0,
        selection: :coverage_with_static_fallback,
        concurrency: System.schedulers_online()

  ## Source-level ignores

  Add `@mutalisk_ignore true` to a module to exclude every mutant in that
  module (generated/DSL modules, intentionally-untested code):

      defmodule MyApp.Generated do
        @mutalisk_ignore true
        # ... no mutants are produced for this module ...
      end

  Run as `MIX_ENV=test mix mut`.
  """

  use Mix.Task

  alias Mut.Cli
  alias Mut.Coverage.Runner, as: CoverageRunner
  alias Mut.CoverageOracle
  alias Mut.History
  alias Mut.Metrics
  alias Mut.Reporter.GitHubActions
  alias Mut.Reporter.Html
  alias Mut.Reporter.StrykerJson
  alias Mut.Reporter.Terminal
  alias Mut.Sandbox
  alias Mut.Selection.DowngradeHint
  alias Mut.TestSelection.Coverage, as: CoverageSelection
  alias Mut.TestSelection.Static
  alias Mut.Worker

  @requirements ["app.config"]
  # Buffer added on top of `--test-timeout-ms` for the host-side
  # deadline. ExUnit fires its per-test timeout first and emits a
  # MUT_RESULT line; the host then needs time to drain the port and
  # classify. 10s matches v1.8 (the old 70 000 = 60 000 + 10 000).
  @host_deadline_buffer_ms 10_000
  @coverage_pathology_floor_ms 10_000
  # R5: finite backstop for the baseline suite (includes an implicit compile);
  # generous enough not to false-fail a large suite, finite enough to recover
  # from a hang.
  @baseline_timeout_ms 1_200_000
  @mutalisk_root Path.expand("../../..", __DIR__)

  @impl Mix.Task
  def run(["--help"]), do: print_help()
  def run(["-h"]), do: print_help()

  def run(argv) do
    enforce_test_env!()

    # Effective config: `.mutalisk.exs` (project file) < `config :mut` < CLI
    # flags. Mut.Config merges the first two; Cli.parse layers CLI flags on top.
    case Cli.parse(argv, Mut.Config.load(File.cwd!())) do
      {:ok, opts} -> run_pipeline(opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp print_help do
    @moduledoc
    |> String.trim()
    |> Mix.shell().info()
  end

  defp run_pipeline(opts) do
    target_root = File.cwd!()
    # Validate (and prepare) report output paths and warn on no-op flag combos
    # BEFORE the expensive oracle/schema build, so bad input fails fast instead
    # of crashing after minutes of work (Exploratory #44) or running silently
    # with no effect (#15). Skipped under --debug-plan, which writes no report.
    unless opts.debug_plan, do: validate_output_paths!(target_root, opts)
    warn_unused_since(opts)
    warn_unused_output_path(opts)
    mutalisk_root = @mutalisk_root
    # #40/#49: every runtime artifact (work copies, sandboxes, memory/baseline
    # logs) lives under this target-scoped OS-temp root — NEVER under the mutalisk
    # dependency checkout, which `mix deps.clean` wipes, CI caches surprise, and
    # can be read-only. See `artifact_root/1` for why OS-temp over the target's
    # `_build`.
    artifact_root = artifact_root(target_root)
    run_id = run_id()
    started = System.monotonic_time(:millisecond)
    {:ok, metrics_pid} = Metrics.start_link([])
    Metrics.set_concurrency(metrics_pid, opts.concurrency)
    Metrics.set_test_timeout_ms(metrics_pid, opts.test_timeout_ms)

    {:ok, watchdog_pid} =
      Mut.MemoryWatchdog.start(Path.join(artifact_root, "mut_memory.log"))

    try do
      IO.puts("Oracle build starting")

      {:ok, oracle} =
        Metrics.with_phase(metrics_pid, :oracle_build, fn ->
          # The `File.cd!(mutalisk_root, ...)` here is NOT for steering artifact
          # locations (those are passed explicitly via `:root`); it makes the
          # `File.cwd!()`-derived `MUTALISK_PATH` in `Mut.OracleBuild`'s child mix
          # env resolve to the mutalisk checkout, so the work copy's overlay pins
          # `{:mutalisk, path: <checkout>}`.
          File.cd!(mutalisk_root, fn ->
            Mut.OracleBuild.run(target_root,
              run_id: run_id,
              force: true,
              keep: true,
              root: artifact_root
            )
          end)
        end)

      IO.puts("Oracle build complete")

      work_copy = Path.join([artifact_root, "mut_work", run_id])

      IO.puts("Baseline tests starting")

      Metrics.with_phase(metrics_pid, :baseline_tests, fn ->
        baseline_tests!(work_copy, mutalisk_root, artifact_root, opts, run_id)
      end)

      IO.puts("Baseline tests complete")

      baseline_tests_ms = Metrics.snapshot(metrics_pid).phase_timings.baseline_tests_ms

      IO.puts("Plan generation starting")

      plan =
        Metrics.with_phase(metrics_pid, :plan_generation, fn ->
          build_plan(work_copy, oracle, opts, target_root)
        end)

      plan = maybe_limit_plan(plan, opts.max_mutants)
      IO.puts("Plan generation complete")

      if opts.debug_plan do
        plan_path = Path.join(target_root, "plan.debug.json")
        Mut.Plan.dump_json(plan, plan_path)
        # #43: confirm the write + counts rather than exiting silently.
        schema_n = length(plan.schema)
        fallback_n = length(plan.fallback)
        skipped_n = length(plan.skipped)
        invalid_n = Enum.count(plan.skipped, &(&1.reason in [:invalid, "invalid"]))

        IO.puts(
          "[mutalisk] --debug-plan: wrote #{plan_path} " <>
            "(#{schema_n + fallback_n} executable: #{schema_n} schema, #{fallback_n} fallback; " <>
            "#{skipped_n} skipped, #{invalid_n} invalid)"
        )

        set_debug_plan_exit_code(plan, opts.fail_at)
      else
        if executable_count(plan) == 0 do
          execute_empty_plan(plan, work_copy, target_root, opts, metrics_pid)
        else
          {coverage_oracle, selection_mode} =
            collect_coverage_for_selection(
              target_root,
              work_copy,
              opts,
              metrics_pid,
              baseline_tests_ms
            )

          # M109: under `--incremental`, partition + record reused verdicts BEFORE
          # schema build so reused mutants are pruned from instrumentation. The
          # plan handed to `execute_plan` is the to-execute subset; reused verdicts
          # are already recorded in the ledger and appear in the report/score.
          # Non-incremental: no-op (full plan, nothing recorded) → v1.29-identical.
          exec_plan =
            prune_reused_for_incremental(
              plan,
              work_copy,
              opts,
              coverage_oracle,
              selection_mode,
              metrics_pid,
              target_root
            )

          # As with the oracle build, this `File.cd!(mutalisk_root, ...)` exists
          # only so the `File.cwd!()`-derived `MUTALISK_PATH` in the schema-build
          # and worker child mix envs points at the mutalisk checkout. Artifact
          # locations (schema work copy, sandbox pool) are passed explicitly via
          # `artifact_root`, so they land under the target-scoped temp root
          # regardless of cwd.
          File.cd!(mutalisk_root, fn ->
            execute_plan(
              exec_plan,
              target_root,
              artifact_root,
              run_id,
              opts,
              metrics_pid,
              coverage_oracle,
              selection_mode
            )
          end)
        end
      end
    after
      Mut.MemoryWatchdog.stop(watchdog_pid)

      if opts.keep_work_copy do
        IO.puts(
          :stderr,
          "[mutalisk] --keep-work-copy: retaining oracle/baseline work copy #{Path.join([artifact_root, "mut_work", run_id])}"
        )
      else
        File.rm_rf!(Path.join([artifact_root, "mut_work", run_id]))
      end
    end

    unless opts.debug_plan do
      IO.puts("Mutalisk run complete in #{elapsed(started)}ms")
    end
  end

  defp execute_empty_plan(plan, work_copy, target_root, opts, metrics_pid) do
    Metrics.set_effective_concurrency(metrics_pid, 1)
    Metrics.set_planned_total(metrics_pid, 0)
    record_skipped_plan(metrics_pid, plan)

    snapshot =
      render_reports_with_timing(
        metrics_pid,
        plan,
        work_copy,
        target_root,
        opts
      )

    set_exit_code(snapshot, opts.fail_at)
  end

  # R15: destroying the original `pool` (the precisely-typed opaque
  # `Sandbox.Pool` from `create_pool`) inside the `after` trips dialyzer's
  # cross-module opaqueness check — the prior `final_pool` came back through the
  # run functions with a looser type. `Sandbox` already exempts `destroy_pool/1`
  # via `{:no_opaque, ...}`; mirror that at this call site.
  @dialyzer {:no_opaque, execute_plan: 8}
  defp execute_plan(
         plan,
         target_root,
         artifact_root,
         run_id,
         opts,
         metrics_pid,
         coverage_oracle,
         selection_mode
       ) do
    IO.puts("Schema build starting")

    {:ok, schema_result} =
      Metrics.with_phase(metrics_pid, :schema_build, fn ->
        Mut.SchemaBuild.build(plan,
          user_project_root: target_root,
          run_id: "#{run_id}-schema",
          force: true,
          keep: true,
          root: artifact_root
        )
      end)

    IO.puts("Schema build complete")

    # Never materialize more sandboxes than there are mutants to run: a tiny run
    # with a large `--concurrency` (e.g. `--concurrency 999 --max-mutants 1`)
    # otherwise spends minutes creating/tearing down a huge pool for no benefit
    # (Exploratory #57). The capped value also drives the reported "effective"
    # worker count so the summary is accurate (#58).
    mutant_count = executable_count(schema_result.plan)
    effective_concurrency = max(1, min(opts.concurrency, mutant_count))
    Metrics.set_effective_concurrency(metrics_pid, effective_concurrency)

    {:ok, pool} =
      Sandbox.create_pool(schema_result, effective_concurrency,
        run_id: run_id,
        force: true,
        root: artifact_root
      )

    {:ok, last_killer} = Mut.LastKiller.start_link([])
    progress_pid = start_progress(opts)

    Metrics.set_planned_total(metrics_pid, executable_count(schema_result.plan))

    {snapshot, _final_pool} =
      try do
        record_schema_build_metadata(metrics_pid, schema_result)

        source_root = schema_result.work_copy_root

        all_test_files =
          Mut.TestSelection.discover_test_files(absolute_test_paths(source_root, opts))

        selection_context =
          build_selection_context(
            schema_result.plan,
            source_root,
            opts,
            coverage_oracle,
            selection_mode,
            last_killer,
            all_test_files
          )

        ctx = %{
          selection_context: selection_context,
          all_test_files: all_test_files,
          work_copy: source_root,
          metrics_pid: metrics_pid,
          last_killer: last_killer,
          progress_pid: progress_pid,
          concurrency: effective_concurrency,
          test_timeout_ms: opts.test_timeout_ms,
          host_deadline_ms: opts.test_timeout_ms + @host_deadline_buffer_ms
        }

        # M109: the `--incremental` reuse partition + reused-verdict recording
        # now happen *before* schema build (in `run_pipeline`), so reused
        # mutants are pruned from the plan that drives instrumentation. By here
        # `schema_result.plan` is already the to-execute subset — run and render
        # it directly (the reused verdicts are in the ledger). Non-incremental
        # runs prune nothing, so this is the full plan, byte-identical to v1.29.
        pool =
          Metrics.with_phase(metrics_pid, :schema_workers, fn ->
            run_schema_mutants(pool, schema_result.plan, ctx)
          end)

        final_pool =
          Metrics.with_phase(metrics_pid, :fallback_workers, fn ->
            run_fallback_mutants(pool, schema_result.plan, ctx)
          end)

        snapshot =
          render_reports_with_timing(
            metrics_pid,
            schema_result.plan,
            source_root,
            target_root,
            opts
          )

        {snapshot, final_pool}
      after
        # T14: persist incremental history in `after`, snapshotting the live
        # metrics ledger — so a mid-run abort (worker crash, Ctrl-C, render
        # failure) still records the verdicts produced so far for the next
        # `--incremental` run, instead of only writing at the very end. Runs
        # BEFORE the work copy is removed (digests need that source) and is
        # wrapped to never raise. The reuse decision is already guarded by
        # per-mutant digests, so a partial store is safe to reuse.
        write_history(
          Metrics.snapshot(metrics_pid),
          schema_result.work_copy_root,
          target_root,
          opts
        )

        # R15: destroy the sandbox pool inside `after`, not after the try — an
        # exception in the body (a worker crash, a render failure) otherwise
        # skipped this and leaked every sandbox directory. All sandboxes share
        # fixed paths under the run's pool dir, so destroying the original
        # `pool` reclaims them regardless of checkout state on the failure path.
        Sandbox.destroy_pool(pool)

        if opts.keep_work_copy do
          IO.puts(
            :stderr,
            "[mutalisk] --keep-work-copy: retaining schema-build work copy #{schema_result.work_copy_root}"
          )
        else
          File.rm_rf!(schema_result.work_copy_root)
        end
      end

    set_exit_code(snapshot, opts.fail_at)
  end

  # M105: write the incremental-history verdict store from the run ledger.
  # Function-level source digests are computed against the work-copy source
  # (`source_root`, still present); the store persists in the user project's
  # `_build` (`target_root`). Wrapped so a history failure never aborts a run —
  # history is an optimization, not a correctness input.
  defp write_history(snapshot, source_root, target_root, opts) do
    project_digest = History.Digest.project_digest(source_root)
    records = history_records(snapshot.ledger, source_root, opts.test_timeout_ms, project_digest)
    # P2: honor a configured :history_path on WRITE too (load_verdicts already
    # reads it) — otherwise a custom-path user writes the default store while
    # reading the custom one, and never warms either.
    store_path = History.Store.path(target_root, history_path: opts.history_path)

    prev =
      case load_history_store(store_path, opts) do
        {:ok, store} -> store
        {:cold, _reason} -> :cold
      end

    History.Store.write(store_path, History.Store.build(prev, records))
  rescue
    error ->
      IO.puts(:stderr, "[mutalisk] history write skipped: #{Exception.message(error)}")
      :ok
  end

  defp load_history_store(path, opts) do
    result = History.Store.load(path)

    case result do
      {:cold, reason} when is_binary(opts.history_path) and reason != :missing ->
        IO.puts(
          :stderr,
          "[mutalisk] configured history_path #{path} is unusable (#{reason}); starting cold"
        )

      _ ->
        :ok
    end

    result
  end

  # Reusable verdicts (killed/survived/timeout) from the ledger, digested per
  # file (function index built once per file). `project_digest` is the coarse
  # whole-project fingerprint, identical for every verdict in this run.
  defp history_records(ledger, source_root, test_timeout_ms, project_digest) do
    reusable =
      Enum.filter(ledger, fn entry ->
        Map.has_key?(entry, :mutant) and History.Store.reusable_status?(entry.status)
      end)

    indexes = build_file_indexes(reusable, source_root)
    read_test = fn rel -> read_relative(source_root, rel) end

    reusable
    |> Enum.map(fn entry ->
      mutant = final_mutant(entry)
      index = Map.fetch!(indexes, mutant.file)
      History.Store.record_for(mutant, index, read_test, test_timeout_ms, project_digest)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp final_mutant(entry) do
    %{
      entry.mutant
      | status: entry.status,
        killing_test: entry.killing_test,
        covering_tests: entry.covering_tests
    }
  end

  defp build_file_indexes(entries, source_root) do
    entries
    |> Enum.map(& &1.mutant.file)
    |> Enum.uniq()
    |> Map.new(fn file ->
      source = read_relative(source_root, file) || ""
      {file, History.Digest.function_index(source)}
    end)
  end

  defp read_relative(root, rel) do
    case File.read(Path.join(root, rel)) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  # M109: pre-schema-build incremental partition. Builds a selection context
  # against the oracle work copy (byte-identical source to the schema copy, so
  # digests match), partitions the plan, RECORDS the reused verdicts into the
  # ledger, and returns the to-execute subset — which then drives schema
  # instrumentation, so reused mutants are never instrumented. Non-incremental
  # is a no-op: the full plan is returned untouched, nothing recorded.
  defp prune_reused_for_incremental(
         plan,
         _work_copy,
         %{incremental: false},
         _coverage_oracle,
         _selection_mode,
         _metrics_pid,
         _target_root
       ),
       do: plan

  defp prune_reused_for_incremental(
         plan,
         work_copy,
         opts,
         coverage_oracle,
         selection_mode,
         metrics_pid,
         target_root
       ) do
    all_test_files =
      Mut.TestSelection.discover_test_files(absolute_test_paths(work_copy, opts))

    {:ok, last_killer} = Mut.LastKiller.start_link([])

    try do
      selection_context =
        build_selection_context(
          plan,
          work_copy,
          opts,
          coverage_oracle,
          selection_mode,
          last_killer,
          all_test_files
        )

      ctx = %{
        selection_context: selection_context,
        all_test_files: all_test_files,
        work_copy: work_copy,
        metrics_pid: metrics_pid
      }

      {exec_plan, reused} = apply_incremental_reuse(plan, ctx, opts, work_copy, target_root)
      record_reused(reused, ctx)
      exec_plan
    after
      Agent.stop(last_killer)
    end
  end

  # M106/M109: partition the plan into mutants whose verdict is reused from
  # history (stored digests match the current run) and the executable
  # remainder. Only called under `--incremental` (the non-incremental
  # short-circuit lives in `prune_reused_for_incremental/7`).
  defp apply_incremental_reuse(plan, ctx, opts, source_root, target_root) do
    verdicts = load_verdicts(target_root, opts)

    if map_size(verdicts) == 0 do
      {plan, []}
    else
      changed = changed_files_since(opts.since, target_root)
      indexes = mutant_file_indexes(plan, source_root)
      # Coarse project fingerprint, computed ONCE (same for every mutant). A
      # change to any project source/test-support/config/dep invalidates all
      # reuse (review P1a).
      project_digest = History.Digest.project_digest(source_root)

      {schema_exec, schema_reused} =
        partition_reuse(plan.schema, ctx, opts, verdicts, indexes, changed, project_digest)

      {fallback_exec, fallback_reused} =
        partition_reuse(plan.fallback, ctx, opts, verdicts, indexes, changed, project_digest)

      exec_plan = %{plan | schema: schema_exec, fallback: fallback_exec}
      {exec_plan, schema_reused ++ fallback_reused}
    end
  end

  defp partition_reuse(mutants, ctx, opts, verdicts, indexes, changed, project_digest) do
    {exec, reused} =
      Enum.reduce(mutants, {[], []}, fn mutant, {exec, reused} ->
        current = current_digests(mutant, indexes, ctx, opts, project_digest)
        file_changed? = changed != nil and MapSet.member?(changed, mutant.file)

        case History.Reuse.decide(mutant, verdicts, current, file_changed?) do
          {:reuse, stored} -> {exec, [{mutant, stored} | reused]}
          :execute -> {[mutant | exec], reused}
        end
      end)

    {Enum.reverse(exec), reused}
  end

  # Digests for one planned mutant, computed exactly as `write_history` stored
  # them: the function-level source digest at the mutant's line, the
  # order-insensitive digest over its selected tests' content, and the shared
  # project fingerprint. `selected_tests/2` returns the same set recorded as
  # `covering_tests` (ordering differs but the digest sorts).
  defp current_digests(mutant, indexes, ctx, opts, project_digest) do
    index = Map.fetch!(indexes, mutant.file)
    rel = relative_tests(selected_tests(ctx.selection_context, mutant), ctx.work_copy)
    entries = for path <- rel, content = read_relative(ctx.work_copy, path), do: {path, content}

    %{
      source_digest: History.Digest.source_digest(index, mutant.line),
      selected_tests_digest: History.Digest.selected_tests_digest(entries),
      project_digest: project_digest,
      test_timeout_ms: opts.test_timeout_ms
    }
  end

  defp mutant_file_indexes(plan, source_root) do
    (plan.schema ++ plan.fallback)
    |> Enum.map(& &1.file)
    |> Enum.uniq()
    |> Map.new(fn file ->
      source = read_relative(source_root, file) || ""
      {file, History.Digest.function_index(source)}
    end)
  end

  # Record reused verdicts into metrics as if executed (status from history,
  # zero duration), so they appear in the report + score identically.
  defp record_reused(reused, ctx) do
    Enum.each(reused, fn {mutant, stored} ->
      rel = relative_tests(selected_tests(ctx.selection_context, mutant), ctx.work_copy)
      status = String.to_existing_atom(stored["status"])

      result = %Worker.Result{
        status: status,
        duration_ms: 0,
        # JSON null decodes to the atom `:null`; the reporter expects a binary
        # or nil killing test, so coerce anything non-binary to nil.
        killing_test: binary_or_nil(stored["killing_test"])
      }

      record_result(ctx.metrics_pid, %{mutant | covering_tests: rel}, result)
    end)

    Metrics.add_reused(
      ctx.metrics_pid,
      Enum.map(reused, fn {mutant, _stored} -> mutant.stable_id end)
    )
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp load_verdicts(target_root, opts) do
    case load_history_store(
           History.Store.path(target_root, history_path: opts.history_path),
           opts
         ) do
      {:ok, store} -> store.verdicts
      {:cold, _reason} -> %{}
    end
  end

  defp changed_files_since(nil, _root), do: nil

  defp changed_files_since(ref, root) do
    # T2: `--relative` makes git emit paths relative to `-C root` (the project
    # root) and restrict the diff to files under it. Without it, git returns
    # REPOSITORY-root-relative paths (e.g. `apps/foo/lib/x.ex`), which never
    # match the project-root-relative `mutant.file` (`lib/x.ex`) in a monorepo /
    # umbrella — silently making the `--since` gate inert.
    case System.cmd("git", ["-C", root, "diff", "--name-only", "--relative", ref],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> MapSet.new()

      {output, _code} ->
        # Surface only the first line of git's output. The full text (e.g. the
        # multi-line `git diff --no-index` usage printed when run outside a repo)
        # is noise that buries the actionable message. (Exploratory issue #10.)
        detail =
          output
          |> String.split("\n", trim: true)
          |> List.first()

        suffix = if detail, do: " (#{detail})", else: ""

        IO.puts(
          :stderr,
          "[mutalisk] --since #{ref}: git diff failed#{suffix}; " <>
            "reuse falls back to digest checks only"
        )

        nil
    end
  end

  defp build_plan(work_copy, oracle, opts, project_root) do
    Mut.Orchestrator.plan(work_copy, oracle,
      files: expand_file_patterns(work_copy, opts.files, project_root),
      mutators: Cli.resolve_mutators(opts.mutators),
      enabled_targets: opts.enabled_targets,
      file_filter: opts.exclude
    )
  end

  defp baseline_tests!(work_copy, mutalisk_root, artifact_root, opts, run_id) do
    env = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_oracle"},
      {"MIX_DEPS_PATH", "_build/mut_oracle/deps"},
      {"MUTALISK_ROLE", "schema"},
      # Read-only reference to the mutalisk checkout so the work copy's overlay
      # can pin `{:mutalisk, path: <checkout>}`; not a write target.
      {"MUTALISK_PATH", mutalisk_root}
    ]

    # #40/#41: the baseline log lives under the target-scoped artifact root (not
    # the dependency checkout) and is per-run, so concurrent/repeat runs never
    # clobber a shared `tmp/mut_baseline.log`.
    log_path = Path.join([artifact_root, "mut_baseline-#{run_id}.log"])

    # R2: run the baseline under the SAME per-test timeout as mutant runs. A
    # test that passes under ExUnit's 60s default but exceeds the mutation
    # --timeout (10s default) would otherwise time out under every covering
    # mutant and be silently counted as a kill. Failing it here, up front,
    # makes the mismatch visible instead of a per-mutant false kill.
    test_args =
      [
        "test",
        "--no-deps-check",
        "--no-archives-check",
        "--timeout",
        Integer.to_string(opts.test_timeout_ms)
      ] ++ baseline_test_args(work_copy, opts)

    case Mut.ChildProcess.run("mix", test_args,
           cd: work_copy,
           env: env,
           max_output_bytes: 512_000,
           # R5: a finite backstop so a hanging baseline suite (or a hung
           # compile during `mix test`'s implicit compile) aborts visibly
           # instead of wedging `mix mut` forever — the existing `{:timeout, _}`
           # clause below was dead without this (default was `:infinity`).
           timeout_ms: @baseline_timeout_ms,
           log_path: log_path
         ) do
      {:exit, 0, output} ->
        # A suite that runs zero tests passes (exit 0) but mutation testing is
        # meaningless without tests — every mutant would "error/no-coverage" and
        # the run would falsely look healthy. Fail fast with a clear message
        # (Exploratory #31, #32).
        if no_tests_ran?(output) do
          Mix.raise(
            "baseline ran no tests; aborting mutation run. Mutation testing needs a " <>
              "test suite — add tests, or check `test_paths` / MIX_ENV (full log: #{log_path})"
          )
        else
          :ok
        end

      {:exit, _exit_code, output} ->
        Mix.raise(
          "baseline tests failed; aborting mutation run (full log: #{log_path})\n\n#{output_tail(output)}"
        )

      {:error, reason} ->
        Mix.raise(
          "baseline tests failed; aborting mutation run (full log: #{log_path})\n\n#{inspect(reason)}"
        )

      {:timeout, output} ->
        Mix.raise(
          "baseline tests timed out; aborting mutation run (full log: #{log_path})\n\n#{output_tail(output)}"
        )
    end
  end

  defp baseline_test_args(work_copy, opts),
    do: default_test_paths(work_copy, opts.test_paths)

  # True only when the WHOLE baseline ran zero tests. Umbrella-safe: `mix test`
  # prints one "N tests, M failures" summary per child app, and a test-less child
  # app legitimately prints "0 tests," / "There are no tests to run" while other
  # apps ran many — so we must not abort on the mere presence of those phrases
  # (Exploratory #31, adversarial #3). Sum every reported test count; a non-empty
  # summary aborts only when every app reported 0. With no summary at all, fall
  # back to the "no tests to run" phrase (single-app, no test files).
  defp no_tests_ran?(output) do
    case Regex.scan(~r/(\d+) tests?,/, output) do
      [] -> String.contains?(output, "There are no tests to run")
      matches -> Enum.all?(matches, fn [_full, count] -> count == "0" end)
    end
  end

  defp collect_coverage_for_selection(
         target_root,
         work_copy,
         opts,
         metrics_pid,
         baseline_tests_ms
       ) do
    Metrics.set_selection_mode(metrics_pid, opts.selection)

    case opts.selection do
      :static ->
        Metrics.with_phase(metrics_pid, :coverage_collection, fn -> :ok end)
        Metrics.set_coverage_collection_wall_ms(metrics_pid, 0)
        {nil, :static}

      # #64: only the fallback mode consults the hint — `--selection coverage`
      # is an explicit user override and always attempts collection (it raises
      # on pathology rather than silently downgrading; see
      # `handle_pathological_coverage/6`'s `:coverage` clause).
      :coverage_with_static_fallback ->
        case DowngradeHint.check(target_root) do
          {:skip, hint} ->
            skip_coverage_via_hint(target_root, hint, metrics_pid)

          :collect ->
            collect_coverage!(
              target_root,
              work_copy,
              opts,
              metrics_pid,
              baseline_tests_ms,
              :coverage_with_static_fallback
            )
        end

      :coverage ->
        collect_coverage!(target_root, work_copy, opts, metrics_pid, baseline_tests_ms, :coverage)
    end
  end

  defp collect_coverage!(target_root, work_copy, opts, metrics_pid, baseline_tests_ms, mode) do
    oracle =
      Metrics.with_phase(metrics_pid, :coverage_collection, fn ->
        run_coverage!(work_copy, opts, baseline_tests_ms)
      end)

    wall_ms = oracle.collection_wall_ms
    Metrics.set_coverage_collection_wall_ms(metrics_pid, wall_ms)

    if pathological_coverage_collection?(wall_ms, baseline_tests_ms) do
      handle_pathological_coverage(
        mode,
        wall_ms,
        baseline_tests_ms,
        metrics_pid,
        oracle,
        target_root
      )
    else
      {oracle, mode}
    end
  end

  # #64: skip the collection phase entirely — record a ~0ms phase so metrics
  # stay consistent with the `:static` branch above, rather than omitting the
  # phase.
  defp skip_coverage_via_hint(target_root, hint, metrics_pid) do
    Metrics.with_phase(metrics_pid, :coverage_collection, fn -> :ok end)
    Metrics.set_coverage_collection_wall_ms(metrics_pid, 0)
    Metrics.set_selection_mode(metrics_pid, :downgraded_to_static)

    IO.puts(
      :stderr,
      "[mutalisk] skipping coverage collection: a previous run on this project downgraded " <>
        "to static selection (collection #{Map.get(hint, "coverage_wall_ms")}ms vs baseline " <>
        "#{Map.get(hint, "baseline_tests_ms")}ms). Pass --selection coverage to force " <>
        "collection, or delete #{DowngradeHint.path(target_root)} to reset."
    )

    {nil, :downgraded_to_static}
  end

  @spec pathological_coverage_collection?(non_neg_integer(), non_neg_integer()) :: boolean()
  def pathological_coverage_collection?(coverage_wall_ms, baseline_tests_ms)
      when is_integer(coverage_wall_ms) and is_integer(baseline_tests_ms) do
    coverage_wall_ms > max(baseline_tests_ms * 2, @coverage_pathology_floor_ms)
  end

  defp run_coverage!(work_copy, opts, baseline_tests_ms) do
    case CoverageRunner.run(
           work_copy,
           [
             test_paths: absolute_test_paths(work_copy, opts),
             mutalisk_path: @mutalisk_root
           ] ++
             coverage_timeout_opt(opts) ++ coverage_budget_opt(opts.selection, baseline_tests_ms)
         ) do
      {:ok, oracle} ->
        report_degraded_coverage(oracle)
        oracle

      {:error, reason} ->
        Mix.raise("coverage collection failed: #{inspect(reason)}")
    end
  end

  # T9: pass the configured per-file coverage timeout through, if set; omit it
  # so the runner keeps its built-in default otherwise.
  defp coverage_timeout_opt(%{coverage_timeout_ms: ms}) when is_integer(ms),
    do: [timeout_per_file_ms: ms]

  defp coverage_timeout_opt(_opts), do: []

  defp coverage_budget_opt(:coverage_with_static_fallback, baseline_tests_ms) do
    [collection_budget_ms: max(baseline_tests_ms * 2, @coverage_pathology_floor_ms)]
  end

  defp coverage_budget_opt(_selection, _baseline_tests_ms), do: []

  # M64: surface per-file coverage degradation (crash-tolerant fallback).
  defp report_degraded_coverage(%{degraded_test_files: [_ | _] = degraded}) do
    IO.puts(
      "Coverage: #{length(degraded)} test file(s) degraded to static selection " <>
        "(per-file collection failed; their tests still run for the mutants they " <>
        "statically cover):"
    )

    for {path, reason} <- Enum.take(degraded, 10) do
      IO.puts("  - #{path}: #{degraded_reason(reason)}")
    end
  end

  defp report_degraded_coverage(_oracle), do: :ok

  defp degraded_reason({tag, _file, _a, _b}), do: tag
  defp degraded_reason({tag, _file, _x}), do: tag
  defp degraded_reason(reason) when is_atom(reason), do: reason
  defp degraded_reason(reason), do: inspect(reason, limit: 3)

  defp handle_pathological_coverage(
         :coverage_with_static_fallback,
         wall_ms,
         baseline_ms,
         metrics_pid,
         oracle,
         target_root
       ) do
    IO.puts(
      :stderr,
      "Coverage collection took #{wall_ms}ms vs baseline #{baseline_ms}ms; falling back to static selection."
    )

    Metrics.set_selection_mode(metrics_pid, :downgraded_to_static)
    persist_downgrade_hint(target_root, wall_ms, baseline_ms)
    {oracle, :downgraded_to_static}
  end

  defp handle_pathological_coverage(
         :coverage,
         wall_ms,
         baseline_ms,
         _metrics_pid,
         _oracle,
         _target_root
       ) do
    ratio =
      if baseline_ms == 0,
        do: "inf",
        else: :erlang.float_to_binary(wall_ms / baseline_ms, decimals: 1)

    Mix.raise(
      "Coverage collection took #{wall_ms}ms vs baseline #{baseline_ms}ms (#{ratio}x threshold). Rerun with --selection coverage_with_static_fallback to fall back automatically, or --selection static to skip coverage entirely."
    )
  end

  # #64: persist the downgrade so a future `coverage_with_static_fallback` run
  # on the SAME project (same `project_digest`) can skip collection entirely
  # instead of repeating this ~every-run tax. Non-fatal: a write failure
  # (read-only `_build`, disk full, ...) only warns — it must never fail the
  # run that already has a valid oracle/result in hand.
  defp persist_downgrade_hint(target_root, wall_ms, baseline_ms) do
    digest = History.Digest.project_digest(target_root)

    case DowngradeHint.write(target_root, %{
           coverage_wall_ms: wall_ms,
           baseline_tests_ms: baseline_ms,
           project_digest: digest
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "[mutalisk] warning: could not persist coverage-downgrade hint at " <>
            "#{DowngradeHint.path(target_root)}: #{inspect(reason)}"
        )
    end
  end

  defp build_selection_context(
         plan,
         source_root,
         opts,
         coverage_oracle,
         selection_mode,
         last_killer,
         all_test_files
       ) do
    test_paths = absolute_test_paths(source_root, opts)
    static_analysis = Static.analyze(test_paths)
    oracle = coverage_oracle || %CoverageOracle{}

    # Precompute the base (per-mutant) test selection ONCE per plan. The base
    # membership — which tests cover/statically-match each mutant — is
    # independent of `last_killer`; only the per-mutant *ordering*
    # (`CoverageSelection.order_tests/4`) reads the live last-killer state.
    # Computing the whole-plan selection map per mutant (as the prior code did)
    # was O(N^2) on the hot path; this makes it O(N) base + O(1) lookup +
    # per-mutant ordering. `selected_tests/2` applies the ordering.
    base_selection =
      base_selection(
        selection_mode,
        plan,
        test_paths,
        oracle,
        static_analysis,
        all_test_files,
        source_root
      )

    %{
      plan: plan,
      source_root: source_root,
      test_paths: test_paths,
      static_analysis: static_analysis,
      coverage_oracle: oracle,
      selection_mode: selection_mode,
      last_killer: last_killer,
      all_test_files: all_test_files,
      base_selection: base_selection
    }
  end

  defp base_selection(mode, plan, test_paths, _oracle, _static_analysis, _all_test_files, _root)
       when mode in [:static, :downgraded_to_static] do
    Mut.TestSelection.for_plan(plan, test_paths)
  end

  defp base_selection(_mode, plan, _test_paths, oracle, static_analysis, all_test_files, root) do
    CoverageSelection.base_for_plan(plan, oracle, static_analysis,
      all_test_files: all_test_files,
      root: root
    )
  end

  defp static_match_kind(tests, all_test_files) do
    if tests == [] or length(tests) == length(all_test_files),
      do: :all_tests,
      else: :static_fallback
  end

  defp run_schema_mutants(pool, plan, ctx) do
    run_with_concurrency(pool, plan.schema, ctx.concurrency, fn mutant, sandbox ->
      execute_schema_mutant(mutant, sandbox, ctx)
    end)
  end

  defp run_fallback_mutants(pool, plan, ctx) do
    warn_if_fallback_manifest_unreadable(plan.fallback, ctx)

    run_with_concurrency(pool, plan.fallback, ctx.concurrency, fn mutant, sandbox ->
      execute_fallback_mutant(mutant, sandbox, ctx)
    end)
  end

  # Preflight the Mix manifest ONCE before the fallback phase. Every fallback
  # mutant reads it to compute recompile dependents, so an unreadable manifest
  # (e.g. a new Elixir release bumping the manifest version) otherwise surfaces
  # as N identical cryptic per-mutant errors — one loud diagnostic up front
  # tells the user the whole engine is out, and why. The mutants still run and
  # error individually so they stay visible in the report.
  defp warn_if_fallback_manifest_unreadable([], _ctx), do: :ok

  defp warn_if_fallback_manifest_unreadable([mutant | _rest], ctx) do
    app = fallback_app(ctx.work_copy, mutant)

    manifest_path =
      Path.join([ctx.work_copy, "_build/mut_schema/lib", app, ".mix/compile.elixir"])

    case Mut.MixManifest.read(manifest_path) do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        Mix.shell().error(
          "[mutalisk] fallback engine cannot read the Mix compiler manifest " <>
            "(#{manifest_path}): #{format_manifest_error(reason)}\n" <>
            "[mutalisk] every fallback mutant will be reported as an error; " <>
            "this usually means the Elixir version is newer than mutalisk supports"
        )
    end
  end

  defp format_manifest_error({exception, message}) when is_atom(exception),
    do: "#{inspect(exception)}: #{message}"

  defp execute_schema_mutant(mutant, sandbox, ctx) do
    selected = selected_tests(ctx.selection_context, mutant)
    record_selection_metrics(ctx.metrics_pid, mutant, selected, ctx.work_copy, ctx.all_test_files)
    worker_tests = worker_test_files(selected, ctx.all_test_files, ctx.work_copy)

    result =
      Worker.run_schema(sandbox, mutant.id, worker_tests,
        timeout_ms: ctx.host_deadline_ms,
        test_timeout_ms: ctx.test_timeout_ms,
        retry_on_error: true
      )

    record_after_run(ctx, mutant, selected, result)
  end

  defp execute_fallback_mutant(mutant, sandbox, ctx) do
    selected = selected_tests(ctx.selection_context, mutant)
    record_selection_metrics(ctx.metrics_pid, mutant, selected, ctx.work_copy, ctx.all_test_files)
    worker_tests = worker_test_files(selected, ctx.all_test_files, ctx.work_copy)

    result =
      Worker.run_fallback(sandbox, mutant, worker_tests,
        app: fallback_app(sandbox.path, mutant),
        timeout_ms: ctx.host_deadline_ms,
        test_timeout_ms: ctx.test_timeout_ms
      )

    record_after_run(ctx, mutant, selected, result)
  end

  defp record_after_run(ctx, mutant, selected, result) do
    record_result(
      ctx.metrics_pid,
      %{mutant | covering_tests: relative_tests(selected, ctx.work_copy)},
      result
    )

    record_last_killer(ctx.last_killer, mutant, result, selected)
    maybe_stream_event(ctx.progress_pid, ctx.metrics_pid, mutant, result)
  end

  defp run_with_concurrency(pool, mutants, 1, run_one) do
    mutants
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(pool, fn mutant, pool ->
      {:ok, sandbox, checked_out} = Sandbox.checkout(pool)
      run_one.(mutant, sandbox)
      Sandbox.checkin(sandbox, checked_out)
    end)
  end

  defp run_with_concurrency(pool, mutants, concurrency, run_one) do
    {:ok, queue} = Mut.SandboxQueue.start_link(pool)

    try do
      mutants
      |> Enum.sort_by(& &1.id)
      |> Task.async_stream(
        fn mutant ->
          {:ok, sandbox} = Mut.SandboxQueue.checkout(queue)

          # R6: check the sandbox back in ONLY on normal completion. The fallback
          # path resets the sandbox in its own `after`; if that reset fails twice
          # it raises (a poisoned sandbox would yield false verdicts for every
          # later mutant). On that raise we deliberately do NOT check it back in,
          # so no concurrent worker can pick up the contaminated sandbox before
          # the run tears down. It stays in the pool's `checked_out` set and is
          # still reclaimed by `destroy_pool`, so nothing leaks.
          run_one.(mutant, sandbox)
          Mut.SandboxQueue.checkin(queue, sandbox)
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      Mut.SandboxQueue.finalize(queue)
    rescue
      exception ->
        _ = Mut.SandboxQueue.finalize(queue)
        reraise exception, __STACKTRACE__
    end
  end

  defp start_progress(%{reporters: reporters}) do
    if :terminal in reporters do
      {:ok, pid} = Agent.start_link(fn -> 0 end)
      pid
    end
  end

  defp maybe_stream_event(nil, _metrics_pid, _mutant, _result), do: :ok

  defp maybe_stream_event(progress_pid, metrics_pid, mutant, result) do
    snapshot = Metrics.snapshot(metrics_pid)

    Agent.get_and_update(progress_pid, fn index ->
      next = index + 1
      Terminal.stream_event(snapshot, mutant, result, next)
      {:ok, next}
    end)
  end

  defp record_schema_build_metadata(metrics_pid, schema_result) do
    Enum.each(schema_result.invalid_mutants, fn invalidation ->
      case Enum.find(schema_result.plan.invalid, &(&1.id == invalidation.mutant_id)) do
        nil -> :ok
        mutant -> Metrics.record_invalid(metrics_pid, mutant)
      end
    end)

    schema_result.invalid_mutants
    |> Enum.group_by(& &1.file)
    |> Enum.each(fn {file, invalidations} ->
      Metrics.record_compile_rollback(metrics_pid, file, length(invalidations))
    end)

    record_skipped_plan(metrics_pid, schema_result.plan)
  end

  defp record_skipped_plan(metrics_pid, plan) do
    Enum.each(plan.skipped, fn skipped ->
      Metrics.record_skipped(
        metrics_pid,
        Map.merge(skipped, %{engine: nil, mutation_kind: nil})
      )
    end)
  end

  defp record_result(metrics_pid, mutant, result) do
    Metrics.record_mutant(metrics_pid, mutant, result)
  end

  defp record_selection_metrics(metrics_pid, mutant, selection_result, work_copy, all_test_files) do
    fallback_reason = fallback_reason(metrics_pid, selection_result.match_kind)

    count =
      if selection_result.match_kind == :all_tests and selection_result.test_files == [] do
        length(all_test_files)
      else
        length(relative_tests(selection_result.test_files, work_copy))
      end

    Metrics.record_selection(
      metrics_pid,
      mutant,
      selection_result.match_kind,
      fallback_reason,
      count
    )
  end

  defp fallback_reason(metrics_pid, match_kind) do
    mode = Metrics.snapshot(metrics_pid).selection.mode

    cond do
      match_kind == :exact_line -> nil
      mode == :static -> :static_only_mode
      mode == :downgraded_to_static -> :downgraded_pathological_collection
      match_kind == :enclosing_function -> :no_line_coverage
      true -> :no_function_coverage
    end
  end

  defp record_last_killer(killer, mutant, %{status: :killed} = result, %{
         test_files: [_ | _] = test_files
       }) do
    if mutant.module do
      Mut.LastKiller.record_kill(killer, mutant.module, killer_file(result, test_files))
    end
  end

  defp record_last_killer(_killer, _mutant, _result, _selected), do: :ok

  # The last-killer hint must store the file the killing test ACTUALLY lives in,
  # not the first *selected* file (the prior bug made the prioritisation hint
  # point at a file that didn't kill). The worker reports the killer's file as
  # ExUnit saw it (an absolute sandbox path); match it back to one of the
  # selected files by basename so the stored value is in the same form
  # `order_tests/4` later compares against. Fall back to the first selected file
  # when the killer's file is unknown or unmatched.
  defp killer_file(%{killing_test_file: file}, test_files) when is_binary(file) do
    base = Path.basename(file)

    Enum.find(test_files, hd(test_files), &(Path.basename(&1) == base))
  end

  defp killer_file(_result, [first | _]), do: first

  defp render_reports(snapshot, plan, work_copy, host_root, opts) do
    if :terminal in opts.reporters do
      IO.puts(Terminal.render_summary(snapshot))
    end

    # The Stryker JSON map is the shared data source for the JSON, HTML, and
    # GitHub-Actions reporters — render it once if any of them is enabled.
    if Enum.any?([:stryker_json, :html, :github_actions], &(&1 in opts.reporters)) do
      rendered = render_stryker_report(snapshot, plan, work_copy, opts)

      if :stryker_json in opts.reporters do
        StrykerJson.write(rendered, resolve_output_path(host_root, opts.output_path))
      end

      if :html in opts.reporters do
        Html.write(rendered, resolve_output_path(host_root, html_output_path(opts)))
      end

      if :github_actions in opts.reporters do
        GitHubActions.emit(rendered)
      end
    end
  end

  # HTML report path: the Stryker JSON output path with a `.html` extension
  # (e.g. stryker.report.json -> stryker.report.html).
  defp html_output_path(%{reporters: [:html], output_path: path}) do
    if Path.extname(path) == ".html", do: path, else: Path.rootname(path) <> ".html"
  end

  defp html_output_path(opts) do
    Path.rootname(opts.output_path) <> ".html"
  end

  # Resolve a user output path against the project root, honoring ABSOLUTE paths
  # verbatim. `Path.join(root, "/abs")` strips the leading slash and writes under
  # the project (Exploratory #14); branch on Path.type instead.
  defp resolve_output_path(host_root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(host_root, path)
  end

  # Fail fast on an unwritable report path (e.g. a parent that is a regular file)
  # before the run, rather than crashing in the reporter after all the work is
  # done (Exploratory #44). Creating the dir now is harmless — it is where the
  # report will be written. github_actions writes to stdout, so it is exempt.
  defp validate_output_paths!(host_root, opts) do
    targets = reporter_output_paths(host_root, opts)

    targets
    |> Enum.group_by(fn {_reporter, resolved} -> resolved end, fn {reporter, _resolved} ->
      reporter
    end)
    |> Enum.find(fn {_resolved, reporters} -> length(reporters) > 1 end)
    |> case do
      nil ->
        :ok

      {resolved, reporters} ->
        Mix.raise(
          "report output paths collide at #{resolved}: " <>
            "#{Enum.map_join(reporters, ", ", &reporter_cli_name/1)}"
        )
    end

    targets
    |> Enum.each(fn {reporter, path} ->
      parent = Path.dirname(path)

      if File.dir?(path) do
        Mix.raise("cannot write #{reporter} report to #{path}: target is a directory")
      end

      case File.mkdir_p(parent) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.raise(
            "cannot write #{reporter} report to #{path}: " <>
              "#{:file.format_error(reason)} (#{parent})"
          )
      end
    end)
  end

  defp reporter_output_paths(host_root, opts) do
    [{:stryker_json, opts.output_path}, {:html, html_output_path(opts)}]
    |> Enum.filter(fn {reporter, _path} -> reporter in opts.reporters end)
    |> Enum.map(fn {reporter, path} -> {reporter, resolve_output_path(host_root, path)} end)
  end

  defp reporter_cli_name(reporter), do: reporter |> Atom.to_string() |> String.replace("_", "-")

  # `--since` only affects `--incremental` reuse. Used alone it is silently
  # ignored; warn so a user does not think a change-scoped run happened
  # (Exploratory #15).
  defp warn_unused_since(%{since: since, incremental: false}) when is_binary(since) do
    IO.puts(
      :stderr,
      "[mutalisk] --since #{since} has no effect without --incremental; ignoring it"
    )
  end

  defp warn_unused_since(_opts), do: :ok

  defp warn_unused_output_path(%{reporters: reporters, output_path: path})
       when path != "stryker.report.json" do
    unless Enum.any?([:stryker_json, :html], &(&1 in reporters)) do
      names = Enum.map_join(reporters, ",", &reporter_cli_name/1)

      IO.puts(
        :stderr,
        "[mutalisk] --output-path #{path} has no effect with #{names} reporting; ignoring it"
      )
    end
  end

  defp warn_unused_output_path(_opts), do: :ok

  defp render_reports_with_timing(metrics_pid, plan, work_copy, host_root, opts) do
    Metrics.start_phase(metrics_pid, :report_writing)
    snapshot = Metrics.snapshot(metrics_pid)

    render_reports(snapshot, plan, work_copy, host_root, opts)
    Metrics.end_phase(metrics_pid, :report_writing)
    Metrics.snapshot(metrics_pid)
  end

  # Render + validate the Stryker JSON without writing it (used to time the
  # report build inside the :report_writing phase). Raises on invalid output.
  defp render_stryker_report(snapshot, plan, work_copy, opts) do
    rendered =
      StrykerJson.render(snapshot, plan, source_loader(work_copy),
        thresholds: thresholds(opts.fail_at)
      )

    case StrykerJson.validate(rendered) do
      :ok -> rendered
      {:error, violations} -> Mix.raise("invalid Stryker JSON: #{inspect(violations)}")
    end
  end

  defp maybe_limit_plan(plan, nil), do: plan

  defp maybe_limit_plan(plan, max_mutants) do
    total = length(plan.schema) + length(plan.fallback)

    if total <= max_mutants do
      plan
    else
      keep_ids =
        (plan.schema ++ plan.fallback)
        |> Enum.sort_by(& &1.stable_id)
        |> Enum.take(max_mutants)
        |> Map.new(&{&1.stable_id, true})

      %{
        plan
        | schema: Enum.filter(plan.schema, &Map.has_key?(keep_ids, &1.stable_id)),
          fallback: Enum.filter(plan.fallback, &Map.has_key?(keep_ids, &1.stable_id))
      }
    end
  end

  defp thresholds(fail_at), do: %{"high" => fail_at, "low" => fail_at}

  defp executable_count(plan), do: length(plan.schema) + length(plan.fallback)

  defp selected_tests(%{selection_mode: mode} = context, mutant)
       when mode in [:static, :downgraded_to_static] do
    tests =
      context.base_selection
      |> Map.get(mutant.stable_id, [])
      |> CoverageSelection.order_tests(
        mutant,
        context.coverage_oracle,
        context.last_killer,
        context.source_root
      )

    %{test_files: tests, match_kind: static_match_kind(tests, context.all_test_files)}
  end

  defp selected_tests(context, mutant) do
    base = Map.fetch!(context.base_selection, mutant.stable_id)

    ordered =
      CoverageSelection.order_tests(
        base.test_files,
        mutant,
        context.coverage_oracle,
        context.last_killer,
        context.source_root
      )

    %{base | test_files: ordered}
  end

  defp worker_test_files(selected, all_test_files, work_copy) do
    selected = selected.test_files

    cond do
      selected == [] ->
        []

      length(selected) == length(all_test_files) ->
        Enum.map(all_test_files, &Path.relative_to(&1, work_copy))

      true ->
        Enum.map(selected, &Path.relative_to(&1, work_copy))
    end
  end

  defp relative_tests(%{test_files: selected}, work_copy),
    do: relative_tests(selected, work_copy)

  defp relative_tests(selected, work_copy),
    do: Enum.map(selected, &Path.relative_to(&1, work_copy))

  defp absolute_test_paths(work_copy, opts),
    do: Enum.map(default_test_paths(work_copy, opts.test_paths), &Path.join(work_copy, &1))

  # Resolve the project-relative test directories. An explicit config/CLI
  # `test_paths` is honoured verbatim; the default (`nil`) is umbrella-aware
  # (single app -> `test/`; umbrella -> each child app's `apps/<app>/test/`).
  # Without this an umbrella discovers zero test files, so test-selection metrics
  # record 0 tests/mutant even though the worker still runs the full suite via
  # the empty-selection sentinel. (Exploratory issue #3.)
  defp default_test_paths(_work_copy, paths) when is_list(paths), do: paths
  defp default_test_paths(work_copy, nil), do: Mut.Umbrella.default_test_dirs(work_copy)

  defp expand_file_patterns(_work_copy, nil, _project_root), do: nil

  defp expand_file_patterns(work_copy, patterns, project_root) do
    # Track which patterns matched nothing so a typo / unmatched glob is surfaced
    # rather than silently yielding an empty plan that looks like a clean run.
    # (Exploratory issues #1 and #2.)
    {expanded, unmatched} =
      Enum.reduce(patterns, {[], []}, fn pattern, {acc, miss} ->
        case expand_file_pattern(work_copy, pattern, project_root) do
          [] -> {acc, [pattern | miss]}
          files -> {files ++ acc, miss}
        end
      end)

    warn_unmatched_file_patterns(Enum.reverse(unmatched))

    # Mutalisk mutates compiled `.ex` source. Drop anything else a user points
    # `--files` at — a `README.md` would record a `parse_error` skip (#35) and a
    # `_test.exs` (a `.exs` file) would record noisy `missing_oracle_site` skips
    # (#36). Warn so the drop is visible rather than silent noise in the plan.
    {source, non_source} =
      expanded
      |> Enum.uniq()
      |> Enum.split_with(&String.ends_with?(&1, ".ex"))

    warn_non_source_files(Enum.sort(non_source))

    Enum.sort(source)
  end

  defp warn_non_source_files([]), do: :ok

  defp warn_non_source_files(files) do
    IO.puts(
      :stderr,
      "[mutalisk] --files: ignoring #{length(files)} non-source file(s) " <>
        "(only `.ex` files are mutated): #{Enum.join(files, ", ")}"
    )
  end

  defp warn_unmatched_file_patterns([]), do: :ok

  defp warn_unmatched_file_patterns(patterns) do
    IO.puts(
      :stderr,
      "[mutalisk] --files matched no source files: #{Enum.join(patterns, ", ")}\n" <>
        "  Patterns are resolved relative to the project root (e.g. `lib/foo.ex`, " <>
        "`apps/*/lib/**/*.ex`). Absolute paths inside the project are accepted; " <>
        "paths outside it cannot be mutated."
    )
  end

  defp expand_file_pattern(work_copy, pattern, project_root) do
    path = Path.join(work_copy, normalize_file_pattern(pattern, project_root))

    cond do
      File.dir?(path) ->
        path |> Path.join("**/*.ex") |> wildcard_files(work_copy)

      File.regular?(path) ->
        [Path.relative_to(path, work_copy)]

      true ->
        # A bare glob may match directories too (e.g. `lib/*` over a dir-only
        # tree). Drop them here so a pattern that contributes no real source
        # file is reported as unmatched rather than silently yielding nothing.
        wildcard_files(path, work_copy)
    end
  end

  defp wildcard_files(glob, work_copy) do
    glob
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, work_copy))
  end

  # `--files` patterns are resolved against the sandbox work-copy, whose layout
  # mirrors the project root. An absolute path the user passes points at the
  # original project (the cwd), so relativize it to the project root first;
  # otherwise `Path.join(work_copy, "/abs/path")` never matches and the file is
  # silently dropped. A path outside the project is left unchanged by
  # `relative_to`, so it joins to a non-existent work-copy path that matches
  # nothing and falls through to the unmatched-pattern warning. (Exploratory #1.)
  defp normalize_file_pattern(pattern, project_root) do
    case Path.type(pattern) do
      :absolute -> Path.relative_to(pattern, project_root)
      _ -> pattern
    end
  end

  defp source_loader(root) do
    fn file -> File.read!(Path.join(root, file)) end
  end

  # The OTP app a fallback mutant belongs to. For umbrellas it is the second
  # segment of the mutant's `apps/<app>/lib/...` path (umbrella app dir names
  # must equal their app names); single-app reads the project's :app. M68.
  defp fallback_app(work_copy, mutant) do
    apps_dir = Mut.Umbrella.apps_path_name(work_copy)

    case Path.split(mutant.file) do
      [^apps_dir, app | _] -> app
      _ -> app_name(work_copy)
    end
  end

  defp app_name(work_copy) do
    work_copy
    |> Path.join("mix_user.exs")
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Mut.Umbrella.app_from_ast()
  end

  defp set_exit_code(snapshot, fail_at) do
    errors = Map.get(snapshot.by_status, :error, 0)
    invalid = Map.get(snapshot.by_status, :invalid, 0)
    killed = Map.get(snapshot.by_status, :killed, 0)
    timeout = Map.get(snapshot.by_status, :timeout, 0)
    survived = Map.get(snapshot.by_status, :survived, 0)
    no_coverage = Map.get(snapshot.by_status, :no_coverage, 0)
    scorable = killed + timeout + survived + no_coverage
    inconclusive = errors + invalid
    score = Float.round(snapshot.score, 1)

    cond do
      # No mutant produced a score (empty/unmatched `--files`, or every mutant
      # errored/failed to compile) while a threshold was set. The neutral default
      # score of 100.0 must NOT pass CI (Exploratory #32, #51, #52). `--fail-at 0`
      # is the explicit opt-out for exploratory runs, so only gate when > 0.
      scorable == 0 and fail_at > 0 ->
        detail = if inconclusive > 0, do: " (#{inconclusive} errored/invalid)", else: ""

        IO.puts(
          :stderr,
          "[mutalisk] no scorable mutants#{detail}; failing --fail-at #{fmt_pct(fail_at)}"
        )

        fail_run()

      # Compare the score at the SAME precision it is reported (1 decimal). A raw
      # comparison failed `--fail-at 80` for a 79.96% run that the terminal prints
      # as "80.0%" — the gate and the displayed number must agree. Print the
      # reason to stderr so non-terminal reporters still explain the failure
      # (Exploratory #59, #60, #61).
      score < fail_at ->
        IO.puts(
          :stderr,
          "[mutalisk] mutation score #{fmt_pct(score)} below --fail-at #{fmt_pct(fail_at)}; failing"
        )

        fail_run()

      true ->
        :ok
    end
  end

  defp set_debug_plan_exit_code(plan, fail_at) do
    if executable_count(plan) == 0 and fail_at > 0 do
      IO.puts(
        :stderr,
        "[mutalisk] no scorable mutants; failing --fail-at #{fmt_pct(fail_at)}"
      )

      fail_run()
    end
  end

  defp fmt_pct(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1) <> "%"

  defp fail_run, do: System.at_exit(fn _status -> exit({:shutdown, 1}) end)

  defp enforce_test_env! do
    # `preferred_cli_env: [mut: :test]` (or an aliased task) sets `Mix.env/0` to
    # `:test` WITHOUT the user exporting `MIX_ENV=test`. Gate on the actual Mix
    # env only — every spawned child sets `MIX_ENV=test` in its own env, so the
    # parent shell variable is irrelevant. Requiring the literal var rejected a
    # correctly-configured `preferred_cli_env` setup.
    unless Mix.env() == :test do
      Mix.raise(
        "`mix mut` must run in the test env (MIX_ENV=test or preferred_cli_env: [mut: :test])"
      )
    end
  end

  defp output_tail(output), do: Mut.ChildProcess.output_tail(output)

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "mut-#{System.os_time(:second)}-#{random}"
  end

  # #40/#49: the per-target root for ALL runtime artifacts. We deliberately use
  # the OS temp dir rather than the target project's `_build`: `Mut.WorkCopy`
  # copies the WHOLE project tree and only prunes `_build`/`tmp` AFTER the copy,
  # so a root inside the target's `_build` would recursively self-copy. The
  # temp dir also survives `mix clean`/`mix deps.clean` semantics being irrelevant
  # here — it is transient scratch, cleaned per run. A short hash of the absolute
  # target root scopes the dir per project so concurrent runs of different
  # projects never collide while runs of the same project stay discoverable.
  defp artifact_root(target_root) do
    slug =
      :sha256
      |> :crypto.hash(Path.expand(target_root))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    root = Path.join([System.tmp_dir!(), "mutalisk", slug])
    File.mkdir_p!(root)
    canonical_path(root)
  end

  # Resolve symlinks in the artifact root so the child compiler's real (physical)
  # file paths and the `MUTALISK_PROJECT_ROOT` we hand it agree. On macOS
  # `System.tmp_dir!()` sits under `/var`, a symlink to `/private/var`: the
  # compiler records `__ENV__.file` as `/private/var/...` (getcwd resolves the
  # link) while an unresolved `/var/...` root makes `Path.relative_to` (in
  # `Mut.Trace`) fail to strip the prefix, storing absolute oracle-site keys that
  # never match the work-copy-relative candidate files (every mutant then skips
  # as `missing_oracle_site`). Resolving here keeps both sides byte-identical.
  defp canonical_path(path) do
    {:ok, cwd} = File.cwd()

    try do
      File.cd!(path)
      File.cwd!()
    after
      File.cd!(cwd)
    end
  end
end
