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
    --concurrency N          Worker pool size; parsed for future parallel
                              execution, but M13 runs mutants sequentially
                              (default: System.schedulers_online/0)
    --max-mutants N          Cap total mutants (stable-id sorted sample if
                              exceeded)
    --debug-plan             Dump plan JSON to plan.debug.json and exit before
                              any mutant runs

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
  alias Mut.Metrics
  alias Mut.Reporter.StrykerJson
  alias Mut.Reporter.Terminal
  alias Mut.Sandbox
  alias Mut.Worker

  @requirements ["app.config"]
  @timeout_ms 60_000
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

      plan =
        Metrics.with_phase(metrics_pid, :plan_generation, fn ->
          build_plan(work_copy, oracle, opts)
        end)

      Metrics.with_phase(metrics_pid, :coverage_collection, fn -> :ok end)

      plan = maybe_limit_plan(plan, opts.max_mutants)

      if opts.debug_plan do
        Mut.Plan.dump_json(plan, Path.join(target_root, "plan.debug.json"))
      else
        File.cd!(mutalisk_root, fn ->
          execute_plan(plan, target_root, run_id, opts, started, metrics_pid)
        end)
      end
    after
      File.rm_rf!(Path.join([mutalisk_root, "tmp", "mut_work", run_id]))
    end
  end

  defp execute_plan(plan, target_root, run_id, opts, started, metrics_pid) do
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

    {:ok, pool} = Sandbox.create_pool(schema_result, 1, run_id: run_id, force: true)

    Metrics.set_planned_total(metrics_pid, executable_count(schema_result.plan))

    {snapshot, final_pool} =
      try do
        record_schema_build_metadata(metrics_pid, schema_result)

        source_root = schema_result.work_copy_root

        selection =
          Mut.TestSelection.for_plan(
            schema_result.plan,
            absolute_test_paths(source_root, opts)
          )

        all_test_files =
          Mut.TestSelection.discover_test_files(absolute_test_paths(source_root, opts))

        stream? = :terminal in opts.reporters

        pool =
          Metrics.with_phase(metrics_pid, :schema_workers, fn ->
            run_schema_mutants(
              pool,
              schema_result.plan,
              selection,
              all_test_files,
              source_root,
              metrics_pid,
              stream?
            )
          end)

        final_pool =
          Metrics.with_phase(metrics_pid, :fallback_workers, fn ->
            run_fallback_mutants(
              pool,
              schema_result.plan,
              selection,
              all_test_files,
              source_root,
              metrics_pid,
              stream?
            )
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
        File.rm_rf!(schema_result.work_copy_root)
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
    {output, exit_code} =
      System.cmd("mix", ["test", "--no-deps-check", "--no-archives-check"],
        cd: work_copy,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", "_build/mut_oracle"},
          {"MIX_DEPS_PATH", "_build/mut_oracle/deps"},
          {"MUTALISK_ROLE", "schema"},
          {"MUTALISK_PATH", host_root}
        ],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      Mix.raise("baseline tests failed; aborting mutation run\n\n#{output_tail(output)}")
    end
  end

  defp run_schema_mutants(pool, plan, selection, all_test_files, work_copy, metrics_pid, stream?) do
    plan.schema
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(pool, fn mutant, pool ->
      {:ok, sandbox, checked_out} = Sandbox.checkout(pool)
      selected = selected_tests(selection, mutant)
      worker_tests = worker_test_files(selected, all_test_files, work_copy)

      result =
        Worker.run_schema(sandbox, mutant.id, worker_tests,
          timeout_ms: @timeout_ms,
          retry_on_error: true
        )

      record_result(
        metrics_pid,
        %{mutant | covering_tests: relative_tests(selected, work_copy)},
        result
      )

      maybe_stream_event(stream?, metrics_pid, mutant, result)
      Sandbox.checkin(sandbox, checked_out)
    end)
  end

  defp run_fallback_mutants(
         pool,
         plan,
         selection,
         all_test_files,
         work_copy,
         metrics_pid,
         stream?
       ) do
    plan.fallback
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(pool, fn mutant, pool ->
      {:ok, sandbox, checked_out} = Sandbox.checkout(pool)
      selected = selected_tests(selection, mutant)
      worker_tests = worker_test_files(selected, all_test_files, work_copy)

      result =
        Worker.run_fallback(sandbox, mutant, worker_tests,
          app: app_name(sandbox.path),
          timeout_ms: @timeout_ms
        )

      record_result(
        metrics_pid,
        %{mutant | covering_tests: relative_tests(selected, work_copy)},
        result
      )

      maybe_stream_event(stream?, metrics_pid, mutant, result)
      Sandbox.checkin(sandbox, checked_out)
    end)
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

  defp selected_tests(selection, mutant), do: Map.get(selection, mutant.stable_id, [])

  defp worker_test_files(selected, all_test_files, work_copy) do
    if selected == [] or length(selected) == length(all_test_files) do
      []
    else
      Enum.map(selected, &Path.relative_to(&1, work_copy))
    end
  end

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

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "mut-#{System.os_time(:second)}-#{random}"
  end
end
