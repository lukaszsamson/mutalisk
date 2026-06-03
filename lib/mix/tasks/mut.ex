defmodule Mix.Tasks.Mut do
  @shortdoc "Run mutation testing against the current Mix project."
  @moduledoc """
  Runs mutation testing.

  ## Options

    --files PATTERN          Only mutate files matching glob pattern
    --mutators NAMES         Comma-separated mutator name list
    --enable TARGETS         Comma-separated enabled targets:
                              dispatch (default), guard (default),
                              env_walker (default: only AtomLiteral
                              active; pass it explicitly to run all
                              env-walker literals), module_attribute
                              (opt-in), body_literal (opt-in).
                              Passing --enable selects the full mutator
                              set gated by the listed targets.
    --fail-at SCORE          Mutation score threshold; exit 1 below
                              (default: 80)
    --reporters NAMES        Comma-separated: terminal, stryker-json
                              (default: both)
    --output-path PATH       Stryker JSON output path
                              (default: stryker.report.json)
    --concurrency N          Worker pool size for parallel mutant execution.
                              Default: min(schedulers_online, 4). Use
                              --concurrency 1 for sequential execution.
    --max-mutants N          Cap total mutants (stable-id sorted sample if
                              exceeded)
    --debug-plan             Dump plan JSON to plan.debug.json and exit before
                               any mutant runs
    --selection MODE         Test selection mode: static, coverage,
                               coverage_with_static_fallback (default, since
                               v1.19/M65). `static` is the fully-portable
                               escape hatch.
    --keep-work-copy         Skip cleanup of tmp/mut_work/<run_id>/ on exit
                               (debug aid; default: false)
    --test-timeout-ms N      Per-test ExUnit timeout in milliseconds.
                               Default 10000. Range 1000..600000.

  ## Configuration

  Settings can come from three layers, lowest to highest precedence:

      .mutalisk.exs project file  <  config :mut  <  CLI flags

  A CLI flag always wins; `config :mut` overrides the file; the file is the
  base. Keys (same names in all layers): `files`, `test_paths`, `mutators`,
  `enabled_targets`, `selection`, `fail_at`, `concurrency`, `test_timeout_ms`,
  `reporters`, `output_path`, `exclude`.

  `.mutalisk.exs` (in the project root, loaded if present) is a plain
  keyword-list term — no `Config` runtime needed:

      # .mutalisk.exs
      [
        selection: :coverage_with_static_fallback,
        fail_at: 75.0,
        concurrency: 8,
        enabled_targets: [:dispatch, :guard],
        exclude: [~r"lib/my_app_web/router.ex"]
      ]

  Or via application config:

      config :mut,
        enabled_targets: [:dispatch, :guard],
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
  @mutalisk_root Path.expand("../../..", __DIR__)

  @impl Mix.Task
  def run(argv) do
    enforce_test_env!()

    # Effective config: `.mutalisk.exs` (project file) < `config :mut` < CLI
    # flags. Mut.Config merges the first two; Cli.parse layers CLI flags on top.
    case Cli.parse(argv, Mut.Config.load(File.cwd!())) do
      {:ok, opts} -> run_pipeline(opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp run_pipeline(opts) do
    target_root = File.cwd!()
    mutalisk_root = @mutalisk_root
    run_id = run_id()
    started = System.monotonic_time(:millisecond)
    {:ok, metrics_pid} = Metrics.start_link([])
    Metrics.set_concurrency(metrics_pid, opts.concurrency)
    Metrics.set_test_timeout_ms(metrics_pid, opts.test_timeout_ms)

    {:ok, watchdog_pid} =
      Mut.MemoryWatchdog.start(Path.join([mutalisk_root, "tmp", "mut_memory.log"]))

    try do
      {:ok, oracle} =
        Metrics.with_phase(metrics_pid, :oracle_build, fn ->
          File.cd!(mutalisk_root, fn ->
            Mut.OracleBuild.run(target_root, run_id: run_id, force: true, keep: true)
          end)
        end)

      work_copy = Path.join([mutalisk_root, "tmp", "mut_work", run_id])

      Metrics.with_phase(metrics_pid, :baseline_tests, fn ->
        baseline_tests!(work_copy, mutalisk_root)
      end)

      baseline_tests_ms = Metrics.snapshot(metrics_pid).phase_timings.baseline_tests_ms

      plan =
        Metrics.with_phase(metrics_pid, :plan_generation, fn ->
          build_plan(work_copy, oracle, opts)
        end)

      {coverage_oracle, selection_mode} =
        collect_coverage_for_selection(work_copy, opts, metrics_pid, baseline_tests_ms)

      plan = maybe_limit_plan(plan, opts.max_mutants)

      if opts.debug_plan do
        Mut.Plan.dump_json(plan, Path.join(target_root, "plan.debug.json"))
      else
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

        File.cd!(mutalisk_root, fn ->
          execute_plan(
            exec_plan,
            target_root,
            run_id,
            opts,
            started,
            metrics_pid,
            coverage_oracle,
            selection_mode
          )
        end)
      end
    after
      Mut.MemoryWatchdog.stop(watchdog_pid)

      if opts.keep_work_copy do
        IO.puts(
          :stderr,
          "[mutalisk] --keep-work-copy: retaining #{Path.join([mutalisk_root, "tmp", "mut_work", run_id])}"
        )
      else
        File.rm_rf!(Path.join([mutalisk_root, "tmp", "mut_work", run_id]))
      end
    end
  end

  defp execute_plan(
         plan,
         target_root,
         run_id,
         opts,
         started,
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
          keep: true
        )
      end)

    IO.puts("Schema build complete")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, opts.concurrency, run_id: run_id, force: true)

    {:ok, last_killer} = Mut.LastKiller.start_link([])

    Metrics.set_planned_total(metrics_pid, executable_count(schema_result.plan))

    {snapshot, final_pool} =
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
          stream?: :terminal in opts.reporters,
          concurrency: opts.concurrency,
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

        # M105: record the per-mutant verdict store for incremental history.
        # Runs before the `after` clause destroys the work copy (digests are
        # computed against the exact source the verdicts came from). Always
        # writes (history accrues for the next run) but changes nothing
        # observable; never aborts the run on failure.
        write_history(snapshot, source_root, target_root, opts)

        {snapshot, final_pool}
      after
        if opts.keep_work_copy do
          IO.puts(
            :stderr,
            "[mutalisk] --keep-work-copy: retaining #{schema_result.work_copy_root}"
          )
        else
          File.rm_rf!(schema_result.work_copy_root)
        end
      end

    Sandbox.destroy_pool(final_pool)
    set_exit_code(snapshot, opts.fail_at)
    IO.puts("Mutalisk run complete in #{elapsed(started)}ms")
  end

  # M105: write the incremental-history verdict store from the run ledger.
  # Function-level source digests are computed against the work-copy source
  # (`source_root`, still present); the store persists in the user project's
  # `_build` (`target_root`). Wrapped so a history failure never aborts a run —
  # history is an optimization, not a correctness input.
  defp write_history(snapshot, source_root, target_root, opts) do
    records = history_records(snapshot.ledger, source_root, opts.test_timeout_ms)
    store_path = History.Store.path(target_root)

    prev =
      case History.Store.load(store_path) do
        {:ok, store} -> store
        {:cold, _reason} -> :cold
      end

    History.Store.write(store_path, History.Store.build(prev, records))
  rescue
    error ->
      IO.puts(:stderr, "[mutalisk] history write skipped: #{Exception.message(error)}")
      :ok
  end

  # Reusable verdicts (killed/survived/timeout) from the ledger, digested per
  # file (function index built once per file).
  defp history_records(ledger, source_root, test_timeout_ms) do
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
      History.Store.record_for(mutant, index, read_test, test_timeout_ms)
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

      {schema_exec, schema_reused} =
        partition_reuse(plan.schema, ctx, opts, verdicts, indexes, changed)

      {fallback_exec, fallback_reused} =
        partition_reuse(plan.fallback, ctx, opts, verdicts, indexes, changed)

      exec_plan = %{plan | schema: schema_exec, fallback: fallback_exec}
      {exec_plan, schema_reused ++ fallback_reused}
    end
  end

  defp partition_reuse(mutants, ctx, opts, verdicts, indexes, changed) do
    {exec, reused} =
      Enum.reduce(mutants, {[], []}, fn mutant, {exec, reused} ->
        current = current_digests(mutant, indexes, ctx, opts)
        file_changed? = changed != nil and MapSet.member?(changed, mutant.file)

        case History.Reuse.decide(mutant, verdicts, current, file_changed?) do
          {:reuse, stored} -> {exec, [{mutant, stored} | reused]}
          :execute -> {[mutant | exec], reused}
        end
      end)

    {Enum.reverse(exec), reused}
  end

  # Digests for one planned mutant, computed exactly as M105 stored them: the
  # function-level source digest at the mutant's line + the order-insensitive
  # digest over its selected tests' content. `selected_tests/2` returns the same
  # set M105 recorded as `covering_tests` (ordering differs but the digest sorts).
  defp current_digests(mutant, indexes, ctx, opts) do
    index = Map.fetch!(indexes, mutant.file)
    rel = relative_tests(selected_tests(ctx.selection_context, mutant), ctx.work_copy)
    entries = for path <- rel, content = read_relative(ctx.work_copy, path), do: {path, content}

    %{
      source_digest: History.Digest.source_digest(index, mutant.line),
      selected_tests_digest: History.Digest.selected_tests_digest(entries),
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
    case History.Store.load(History.Store.path(target_root, history_path: opts.history_path)) do
      {:ok, store} -> store.verdicts
      {:cold, _reason} -> %{}
    end
  end

  defp changed_files_since(nil, _root), do: nil

  defp changed_files_since(ref, root) do
    case System.cmd("git", ["-C", root, "diff", "--name-only", ref], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> MapSet.new()

      {output, _code} ->
        IO.puts(
          :stderr,
          "[mutalisk] --since #{ref}: git diff failed; reuse falls back to digest checks only\n" <>
            String.trim(output)
        )

        nil
    end
  end

  defp build_plan(work_copy, oracle, opts) do
    Mut.Orchestrator.plan(work_copy, oracle,
      files: expand_file_patterns(work_copy, opts.files),
      mutators: Cli.resolve_mutators(opts.mutators),
      enabled_targets: opts.enabled_targets,
      file_filter: opts.exclude
    )
  end

  defp baseline_tests!(work_copy, host_root) do
    env = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_oracle"},
      {"MIX_DEPS_PATH", "_build/mut_oracle/deps"},
      {"MUTALISK_ROLE", "schema"},
      {"MUTALISK_PATH", host_root}
    ]

    log_path = Path.join([host_root, "tmp", "mut_baseline.log"])

    case Mut.ChildProcess.run("mix", ["test", "--no-deps-check", "--no-archives-check"],
           cd: work_copy,
           env: env,
           max_output_bytes: 512_000,
           log_path: log_path
         ) do
      {:exit, 0, _output} ->
        :ok

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

  defp collect_coverage_for_selection(work_copy, opts, metrics_pid, baseline_tests_ms) do
    Metrics.set_selection_mode(metrics_pid, opts.selection)

    case opts.selection do
      :static ->
        Metrics.with_phase(metrics_pid, :coverage_collection, fn -> :ok end)
        Metrics.set_coverage_collection_wall_ms(metrics_pid, 0)
        {nil, :static}

      mode when mode in [:coverage, :coverage_with_static_fallback] ->
        oracle =
          Metrics.with_phase(metrics_pid, :coverage_collection, fn ->
            run_coverage!(work_copy, opts)
          end)

        wall_ms = oracle.collection_wall_ms
        Metrics.set_coverage_collection_wall_ms(metrics_pid, wall_ms)

        if pathological_coverage_collection?(wall_ms, baseline_tests_ms) do
          handle_pathological_coverage(mode, wall_ms, baseline_tests_ms, metrics_pid, oracle)
        else
          {oracle, mode}
        end
    end
  end

  @spec pathological_coverage_collection?(non_neg_integer(), non_neg_integer()) :: boolean()
  def pathological_coverage_collection?(coverage_wall_ms, baseline_tests_ms)
      when is_integer(coverage_wall_ms) and is_integer(baseline_tests_ms) do
    coverage_wall_ms > max(baseline_tests_ms * 2, @coverage_pathology_floor_ms)
  end

  defp run_coverage!(work_copy, opts) do
    case CoverageRunner.run(work_copy,
           test_paths: absolute_test_paths(work_copy, opts),
           mutalisk_path: @mutalisk_root
         ) do
      {:ok, oracle} ->
        report_degraded_coverage(oracle)
        oracle

      {:error, reason} ->
        Mix.raise("coverage collection failed: #{inspect(reason)}")
    end
  end

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
         oracle
       ) do
    IO.puts(
      :stderr,
      "Coverage collection took #{wall_ms}ms vs baseline #{baseline_ms}ms; falling back to static selection."
    )

    Metrics.set_selection_mode(metrics_pid, :downgraded_to_static)
    {oracle, :downgraded_to_static}
  end

  defp handle_pathological_coverage(:coverage, wall_ms, baseline_ms, _metrics_pid, _oracle) do
    ratio =
      if baseline_ms == 0,
        do: "inf",
        else: :erlang.float_to_binary(wall_ms / baseline_ms, decimals: 1)

    Mix.raise(
      "Coverage collection took #{wall_ms}ms vs baseline #{baseline_ms}ms (#{ratio}x threshold). Rerun with --selection coverage_with_static_fallback to fall back automatically, or --selection static to skip coverage entirely."
    )
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
    run_with_concurrency(pool, plan.fallback, ctx.concurrency, fn mutant, sandbox ->
      execute_fallback_mutant(mutant, sandbox, ctx)
    end)
  end

  defp execute_schema_mutant(mutant, sandbox, ctx) do
    selected = selected_tests(ctx.selection_context, mutant)
    record_selection_metrics(ctx.metrics_pid, mutant, selected, ctx.work_copy)
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
    record_selection_metrics(ctx.metrics_pid, mutant, selected, ctx.work_copy)
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
    maybe_stream_event(ctx.stream?, ctx.metrics_pid, mutant, result)
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

          try do
            run_one.(mutant, sandbox)
          after
            Mut.SandboxQueue.checkin(queue, sandbox)
          end
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

  defp maybe_stream_event(true, metrics_pid, mutant, result) do
    Terminal.stream_event(Metrics.snapshot(metrics_pid), mutant, result)
  end

  defp maybe_stream_event(false, _metrics_pid, _mutant, _result), do: :ok

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

    Enum.each(schema_result.plan.skipped, fn skipped ->
      Metrics.record_skipped(
        metrics_pid,
        Map.merge(skipped, %{engine: nil, mutation_kind: nil})
      )
    end)
  end

  defp record_result(metrics_pid, mutant, result) do
    Metrics.record_mutant(metrics_pid, mutant, result)
  end

  defp record_selection_metrics(metrics_pid, mutant, selection_result, work_copy) do
    fallback_reason = fallback_reason(metrics_pid, selection_result.match_kind)
    count = length(relative_tests(selection_result.test_files, work_copy))

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

  defp record_last_killer(killer, mutant, %{status: :killed}, %{test_files: [test_file | _]}) do
    if mutant.module, do: Mut.LastKiller.record_kill(killer, mutant.module, test_file)
  end

  defp record_last_killer(_killer, _mutant, _result, _selected), do: :ok

  defp render_reports(snapshot, plan, work_copy, host_root, opts) do
    if :terminal in opts.reporters do
      IO.puts(Terminal.render_summary(snapshot))
    end

    # The Stryker JSON map is the shared data source for the JSON, HTML, and
    # GitHub-Actions reporters — render it once if any of them is enabled.
    if Enum.any?([:stryker_json, :html, :github_actions], &(&1 in opts.reporters)) do
      rendered = render_stryker_report(snapshot, plan, work_copy, opts)

      if :stryker_json in opts.reporters do
        StrykerJson.write(rendered, Path.join(host_root, opts.output_path))
      end

      if :html in opts.reporters do
        Html.write(rendered, Path.join(host_root, html_output_path(opts)))
      end

      if :github_actions in opts.reporters do
        GitHubActions.emit(rendered)
      end
    end
  end

  # HTML report path: the Stryker JSON output path with a `.html` extension
  # (e.g. stryker.report.json -> stryker.report.html).
  defp html_output_path(opts) do
    Path.rootname(opts.output_path) <> ".html"
  end

  defp render_reports_with_timing(metrics_pid, plan, work_copy, host_root, opts) do
    Metrics.start_phase(metrics_pid, :report_writing)
    snapshot = Metrics.snapshot(metrics_pid)

    # Render (and validate) inside the timed phase to capture the report-build
    # cost, but DON'T write the file yet: the file is written exactly once,
    # after the phase closes, from the snapshot that includes this phase's
    # timing. Previously the JSON was written here AND again below — a wasted
    # write plus an independent failure point on the discarded first write.
    if :terminal in opts.reporters do
      _iodata = Terminal.render_summary(snapshot)
    end

    if :stryker_json in opts.reporters do
      _rendered = render_stryker_report(snapshot, plan, work_copy, opts)
    end

    Metrics.end_phase(metrics_pid, :report_writing)
    snapshot = Metrics.snapshot(metrics_pid)
    render_reports(snapshot, plan, work_copy, host_root, opts)
    snapshot
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

    if selected == [] or length(selected) == length(all_test_files) do
      []
    else
      Enum.map(selected, &Path.relative_to(&1, work_copy))
    end
  end

  defp relative_tests(%{test_files: selected}, work_copy),
    do: relative_tests(selected, work_copy)

  defp relative_tests(selected, work_copy),
    do: Enum.map(selected, &Path.relative_to(&1, work_copy))

  defp absolute_test_paths(work_copy, opts),
    do: Enum.map(opts.test_paths, &Path.join(work_copy, &1))

  defp expand_file_patterns(_work_copy, nil), do: nil

  defp expand_file_patterns(work_copy, patterns) do
    patterns
    |> Enum.flat_map(&expand_file_pattern(work_copy, &1))
    |> Enum.reject(&File.dir?(Path.join(work_copy, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_file_pattern(work_copy, pattern) do
    path = Path.join(work_copy, pattern)

    cond do
      File.dir?(path) ->
        path
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, work_copy))

      File.regular?(path) ->
        [Path.relative_to(path, work_copy)]

      true ->
        path
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, work_copy))
    end
  end

  defp source_loader(root) do
    fn file -> File.read!(Path.join(root, file)) end
  end

  # The OTP app a fallback mutant belongs to. For umbrellas it is the second
  # segment of the mutant's `apps/<app>/lib/...` path (umbrella app dir names
  # must equal their app names); single-app reads the project's :app. M68.
  defp fallback_app(work_copy, mutant) do
    case Path.split(mutant.file) do
      ["apps", app | _] -> app
      _ -> app_name(work_copy)
    end
  end

  defp app_name(work_copy) do
    work_copy
    |> Path.join("mix_user.exs")
    |> File.read!()
    |> Code.string_to_quoted!()
    |> app_from_ast()
  end

  defp app_from_ast(ast) do
    {_ast, app} =
      Macro.prewalk(ast, nil, fn
        {:app, _meta, value}, nil when is_atom(value) ->
          {{:app, [], value}, Atom.to_string(value)}

        {:app, value}, nil when is_atom(value) ->
          {{:app, value}, Atom.to_string(value)}

        node, app ->
          {node, app}
      end)

    app
  end

  defp set_exit_code(snapshot, fail_at) do
    if snapshot.score < fail_at do
      System.at_exit(fn _status -> exit({:shutdown, 1}) end)
    end
  end

  defp enforce_test_env! do
    unless Mix.env() == :test and System.get_env("MIX_ENV") == "test" do
      Mix.raise("run `MIX_ENV=test mix mut`")
    end
  end

  defp output_tail(output), do: Mut.ChildProcess.output_tail(output)

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "mut-#{System.os_time(:second)}-#{random}"
  end
end
