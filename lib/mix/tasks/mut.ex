defmodule Mix.Tasks.Mut do
  @shortdoc "Run mutation testing against the current Mix project."
  @moduledoc """
  Runs mutation testing.

  ## Options

    --files PATTERN          Only mutate files matching glob pattern
    --mutators NAMES         Comma-separated mutator name list
    --enable TARGETS         Comma-separated enabled targets:
                              dispatch (default), guard (default),
                              module_attribute (opt-in)
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
    --selection MODE         Test selection mode: static (default), coverage,
                               coverage_with_static_fallback
    --keep-work-copy         Skip cleanup of tmp/mut_work/<run_id>/ on exit
                               (debug aid; default: false)
    --worker-type TYPE       mix (default) | persistent. Persistent is
                               an opt-in worker that keeps one ExUnit
                               BEAM alive per sandbox and flips
                               :persistent_term per mutant. Schema
                               mutants only; fallback continues to use
                               mix-spawn.

  Configuration via `config :mut`:

      config :mut,
        files: ["lib"],
        test_paths: ["test"],
        mutators: [:arithmetic, :comparison, :boolean,
                   :guard_comparison],
        enabled_targets: [:dispatch, :guard],
        exclude: [~r/lib\\/my_app_web\\/router.ex/],
        fail_at: 80.0,
        concurrency: System.schedulers_online(),
        timeout_factor: 2.0,
        timeout_const: 1000,
        reporters: [:terminal, :stryker_json]

  CLI flags override config.

  Run as `MIX_ENV=test mix mut`.
  """

  use Mix.Task

  alias Mut.Cli
  alias Mut.Coverage.Runner, as: CoverageRunner
  alias Mut.CoverageOracle
  alias Mut.Metrics
  alias Mut.Reporter.StrykerJson
  alias Mut.Reporter.Terminal
  alias Mut.Sandbox
  alias Mut.TestSelection.Coverage, as: CoverageSelection
  alias Mut.TestSelection.Static
  alias Mut.Worker
  alias Mut.Worker.Persistent

  @requirements ["app.config"]
  @timeout_ms 70_000
  @coverage_pathology_floor_ms 10_000
  @mutalisk_root Path.expand("../../..", __DIR__)

  @impl Mix.Task
  def run(argv) do
    enforce_test_env!()

    case Cli.parse(argv, Application.get_all_env(:mut)) do
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
        File.cd!(mutalisk_root, fn ->
          execute_plan(
            plan,
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

    persistent_servers = maybe_start_persistent_workers(opts, pool)

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
          worker_type: opts.worker_type,
          persistent_servers: persistent_servers
        }

        pool =
          Metrics.with_phase(metrics_pid, :schema_workers, fn ->
            run_schema_mutants(pool, schema_result.plan, ctx)
          end)

        final_pool =
          Metrics.with_phase(metrics_pid, :fallback_workers, fn ->
            run_fallback_mutants(pool, schema_result.plan, ctx)
          end)

        # Drain persistent diagnostic metrics BEFORE snapshot rendering
        # so the rendered Stryker JSON / terminal summary include the
        # mutalisk.persistent block. Workers are still alive here; the
        # `after` clause only stops them once snapshot is built.
        collect_persistent_metrics(persistent_servers, metrics_pid)

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
        stop_persistent_workers(persistent_servers)

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

  defp build_plan(work_copy, oracle, opts) do
    Mut.Orchestrator.plan(work_copy, oracle,
      files: expand_file_patterns(work_copy, opts.files),
      mutators: Cli.resolve_mutators(opts.mutators),
      enabled_targets: opts.enabled_targets,
      file_filter: file_filter()
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
      {:ok, oracle} -> oracle
      {:error, reason} -> Mix.raise("coverage collection failed: #{inspect(reason)}")
    end
  end

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

    %{
      plan: plan,
      source_root: source_root,
      test_paths: test_paths,
      static_analysis: static_analysis,
      coverage_oracle: coverage_oracle || %CoverageOracle{},
      selection_mode: selection_mode,
      last_killer: last_killer,
      all_test_files: all_test_files
    }
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

    result = run_schema_via(ctx, sandbox, mutant, worker_tests)

    record_after_run(ctx, mutant, selected, result)
  end

  defp run_schema_via(%{worker_type: :persistent} = ctx, sandbox, mutant, worker_tests) do
    case Map.get(ctx.persistent_servers, sandbox.id) do
      nil ->
        run_schema_via_mix(sandbox, mutant, worker_tests)

      server ->
        run_schema_via_persistent(ctx, server, sandbox, mutant, worker_tests)
    end
  end

  defp run_schema_via(_ctx, sandbox, mutant, worker_tests),
    do: run_schema_via_mix(sandbox, mutant, worker_tests)

  # Recovery contract (F4 auto-restart + M20 timeout/crash split):
  # - `:filter_miss` — runner couldn't resolve the selected files to
  #   loaded test ids. BEAM is healthy; rerun this mutant via
  #   mix-spawn.
  # - `:timeout` — host deadline expired waiting for MUT_RESULT.
  #   Mix-retry at the same deadline. M20 Phase B explored skipping
  #   the retry (BENCHMARKS.md "Phase B notes") but Decimal
  #   regressed: ~30 mutants are killed in mix-spawn but stall
  #   under persistent's accumulated state. The retry is correct
  #   even though it costs perf — per-sandbox auto-restart still
  #   happens internally, so this sandbox's *next* mutant stays on
  #   persistent.
  # - `:crashed` — runner port exited mid-run (likely a BEAM-level
  #   crash). Mix-retry might succeed where persistent died.
  # - `:exit` (defensive) — the GenServer itself stopped
  #   (auto-restart failed). All future calls also hit this catch
  #   and route to mix; per-sandbox fallback is implicit.
  defp run_schema_via_persistent(_ctx, server, sandbox, mutant, worker_tests) do
    case Persistent.run_schema(server, mutant.id, worker_tests, timeout_ms: @timeout_ms) do
      :timeout ->
        # M21: persistent's `:timeout` is the authoritative result —
        # the test exceeded the per-message deadline and no progress
        # was emitted for `@timeout_ms`. After M21's two fixes
        # (max_failures: 1 in the runner + per-message wait_for_result),
        # persistent is byte-identical to mix on Decimal at c=4
        # (within V17 acceptance). Mix-retry is no longer needed and
        # would cost an extra @timeout_ms per timeout. Materialise
        # Result{status: :timeout} directly. The persistent BEAM has
        # already been auto-restarted by the GenServer, so subsequent
        # mutants on this sandbox stay on persistent.
        %Mut.Worker.Result{status: :timeout, duration_ms: @timeout_ms, raw_output: ""}

      reply when reply in [:filter_miss, :crashed] ->
        run_schema_via_mix(sandbox, mutant, worker_tests)

      %Mut.Worker.Result{} = result ->
        result
    end
  catch
    :exit, _reason ->
      run_schema_via_mix(sandbox, mutant, worker_tests)
  end

  defp run_schema_via_mix(sandbox, mutant, worker_tests) do
    Worker.run_schema(sandbox, mutant.id, worker_tests,
      timeout_ms: @timeout_ms,
      retry_on_error: true
    )
  end

  # Fallback mutants always route through the mix-spawn worker.
  # In-process fallback recompile (V17 step 5) requires :code.purge +
  # :code.load_binary to swap modules inside the persistent BEAM, with
  # module-conflict edge cases that need a separate validation pass.
  # Deferred to follow-up. The mix-spawn fallback path preserves the
  # M17 "0 invalid Decimal fallback" baseline across worker types.

  defp maybe_start_persistent_workers(%{worker_type: :persistent}, pool) do
    pool.sandboxes
    |> Enum.map(fn sandbox ->
      case Persistent.start_link(sandbox) do
        {:ok, pid} -> {sandbox.id, pid}
        {:error, reason} -> Mix.raise("persistent worker start failed: #{inspect(reason)}")
      end
    end)
    |> Map.new()
  end

  defp maybe_start_persistent_workers(_opts, _pool), do: %{}

  defp stop_persistent_workers(servers) do
    Enum.each(servers, fn {_id, pid} ->
      try do
        Persistent.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Drains diagnostic metrics from every live persistent worker before
  # stopping them, then folds the per-worker views into Mut.Metrics
  # so the snapshot's `persistent` block reflects the run.
  defp collect_persistent_metrics(servers, _metrics_pid) when servers == %{}, do: :ok

  defp collect_persistent_metrics(servers, metrics_pid) do
    workers =
      servers
      |> Enum.map(fn {_id, pid} -> Persistent.metrics(pid) end)
      |> Enum.reject(&is_nil/1)

    Metrics.record_persistent_workers(metrics_pid, workers)
    :ok
  end

  defp execute_fallback_mutant(mutant, sandbox, ctx) do
    selected = selected_tests(ctx.selection_context, mutant)
    record_selection_metrics(ctx.metrics_pid, mutant, selected, ctx.work_copy)
    worker_tests = worker_test_files(selected, ctx.all_test_files, ctx.work_copy)

    result =
      Worker.run_fallback(sandbox, mutant, worker_tests,
        app: app_name(sandbox.path),
        timeout_ms: @timeout_ms
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

    if :stryker_json in opts.reporters do
      write_stryker_report(snapshot, plan, work_copy, host_root, opts)
    end
  end

  defp render_reports_with_timing(metrics_pid, plan, work_copy, host_root, opts) do
    Metrics.start_phase(metrics_pid, :report_writing)
    snapshot = Metrics.snapshot(metrics_pid)

    if :terminal in opts.reporters do
      _iodata = Terminal.render_summary(snapshot)
    end

    if :stryker_json in opts.reporters do
      write_stryker_report(snapshot, plan, work_copy, host_root, opts)
    end

    Metrics.end_phase(metrics_pid, :report_writing)
    snapshot = Metrics.snapshot(metrics_pid)
    render_reports(snapshot, plan, work_copy, host_root, opts)
    snapshot
  end

  defp write_stryker_report(snapshot, plan, work_copy, host_root, opts) do
    rendered =
      StrykerJson.render(snapshot, plan, source_loader(work_copy),
        thresholds: thresholds(opts.fail_at)
      )

    case StrykerJson.validate(rendered) do
      :ok -> StrykerJson.write(rendered, Path.join(host_root, opts.output_path))
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
      context.plan
      |> Mut.TestSelection.for_plan(context.test_paths)
      |> Map.get(mutant.stable_id, [])
      |> CoverageSelection.order_tests(
        mutant,
        context.coverage_oracle,
        context.last_killer
      )

    %{test_files: tests, match_kind: static_match_kind(tests, context.all_test_files)}
  end

  defp selected_tests(context, mutant) do
    context.plan
    |> CoverageSelection.for_plan(context.coverage_oracle, context.static_analysis,
      all_test_files: context.all_test_files,
      last_killer: context.last_killer
    )
    |> Map.fetch!(mutant.stable_id)
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

  defp file_filter do
    case Application.get_env(:mut, :exclude) do
      nil ->
        nil

      [] ->
        nil

      [%Regex{} = regex] ->
        regex

      %Regex{} = regex ->
        regex

      regexes when is_list(regexes) ->
        Regex.compile!(Enum.map_join(regexes, "|", &Regex.source/1))
    end
  end

  defp source_loader(root) do
    fn file -> File.read!(Path.join(root, file)) end
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
