defmodule Mix.Tasks.Mut.TestFallback do
  @moduledoc "Integration: run fallback worker against the demo_app fixture."
  use Mix.Task

  alias Mut.Plan

  @shortdoc "Runs fallback worker integration against demo_app"

  @fixture_root Path.expand("test/fixtures/demo_app")
  @fixture_test_paths [Path.join(@fixture_root, "test")]
  @concurrency 1
  @timeout_ms 15_000
  @expected_outcomes %{
    "45edaa4c59d00428222da80093414496" => :survived,
    "6c0a95fb2e147bdddb88354363ae9f4e" => :killed,
    "6d375d71e93497a6b9f9e7b992e76bba" => :killed,
    "7995727a9a8a20c0380a6f23691cd640" => :killed,
    "cce51daa589c14f64bbda5702741877c" => :killed,
    "fec6b0dd35b70d4fb31ed7db9e690194" => :survived
  }

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    started = System.monotonic_time(:millisecond)

    {:ok, oracle} = Mut.OracleBuild.run(@fixture_root, run_id: "m11-oracle", force: true)
    assert_default_attribute_skip!(oracle)

    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle,
        enabled_targets: [:dispatch, :guard, :module_attribute]
      )

    assert_fallback_plan!(plan)

    {:ok, schema_result} =
      Mut.SchemaBuild.build(plan,
        user_project_root: @fixture_root,
        run_id: "m11-schema",
        force: true,
        keep: true
      )

    fallback_plan = %Plan{schema: [], fallback: plan.fallback, skipped: []} |> Plan.finalize()

    {:ok, pool} =
      Mut.Sandbox.create_pool(schema_result, @concurrency, run_id: "m11-fallback", force: true)

    final_pool =
      try do
        selection = Mut.TestSelection.for_plan(fallback_plan, @fixture_test_paths)
        all_test_files = Mut.TestSelection.discover_test_files(@fixture_test_paths)
        {results, pool} = run_mutants(pool, fallback_plan, selection, all_test_files)
        summarize!(results, elapsed(started))
        assert_sandbox_clean!(pool, schema_result)
        pool
      after
        File.rm_rf!(schema_result.work_copy_root)
      end

    Mut.Sandbox.destroy_pool(final_pool)
  end

  defp run_mutants(pool, plan, selection, all_test_files) do
    plan.fallback
    |> Enum.sort_by(& &1.stable_id)
    |> Enum.reduce({[], pool}, fn mutant, {results, pool} ->
      expected = expected(mutant)
      {:ok, sandbox, checked_out} = Mut.Sandbox.checkout(pool)
      selected = Map.fetch!(selection, mutant.stable_id)
      selected_for_worker = worker_test_files(selected, all_test_files)
      dependent_count = dependent_count(sandbox, mutant)

      IO.puts(
        "fallback mutant #{mutant.id} #{String.slice(mutant.stable_id, 0, 8)} #{mutant.description} dependents=#{dependent_count} tests=#{length(selected)}"
      )

      result =
        Mut.Worker.run_fallback(sandbox, mutant, selected_for_worker,
          app: "demo_app",
          timeout_ms: @timeout_ms
        )

      checked_in = Mut.Sandbox.checkin(sandbox, checked_out)

      {[
         %{
           stable_id: mutant.stable_id,
           mutant_id: mutant.id,
           description: mutant.description,
           mutation_kind: mutant.mutation_kind,
           expected: expected,
           actual: result.status,
           killing_test: result.killing_test,
           duration_ms: result.duration_ms,
           dependent_count: dependent_count,
           raw_output: result.raw_output
         }
         | results
       ], checked_in}
    end)
    |> then(fn {results, pool} -> {Enum.reverse(results), pool} end)
  end

  defp summarize!(results, wall_ms) do
    mismatches = Enum.reject(results, &(&1.expected == &1.actual))
    counts = Enum.frequencies_by(results, & &1.actual)
    expected_counts = %{killed: 4, survived: 2}

    IO.puts("mut.test_fallback results=#{inspect(counts)} wall_ms=#{wall_ms}")
    IO.puts("mut.test_fallback dependents=#{inspect(dependent_summary(results))}")

    if mismatches != [] do
      raise "fallback integration mismatches: #{inspect(mismatches, pretty: true)}"
    end

    if counts != expected_counts do
      raise "fallback integration count mismatch: expected #{inspect(expected_counts)}, got #{inspect(counts)}"
    end
  end

  defp assert_sandbox_clean!(pool, schema_result) do
    baselines = baseline_files(schema_result.work_copy_root)

    Enum.each(pool.sandboxes, fn sandbox ->
      Enum.each(baselines, &assert_sandbox_file_clean!(sandbox, schema_result.work_copy_root, &1))
    end)

    IO.puts("mut.test_fallback sandbox_reset=clean")
  end

  defp baseline_files(work_copy_root) do
    work_copy_root
    |> Path.join("lib/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp assert_sandbox_file_clean!(sandbox, work_copy_root, baseline) do
    relative = Path.relative_to(baseline, work_copy_root)
    sandbox_file = Path.join(sandbox.path, relative)

    if File.read!(sandbox_file) != File.read!(baseline) do
      raise "sandbox reset mismatch after fallback run: #{relative}"
    end
  end

  defp dependent_count(sandbox, mutant) do
    manifest_path = Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/.mix/compile.elixir")
    {:ok, manifest} = Mut.MixManifest.read(manifest_path)

    manifest
    |> Mut.Recompile.dependents([mutant.module], [:compile])
    |> Enum.count()
  end

  defp expected(%{stable_id: stable_id}), do: Map.fetch!(@expected_outcomes, stable_id)

  defp worker_test_files(selected, all_test_files) do
    if selected == [] or length(selected) == length(all_test_files) do
      []
    else
      Enum.map(selected, &Path.relative_to(&1, @fixture_root))
    end
  end

  defp dependent_summary(results) do
    Enum.map(results, fn result ->
      {result.mutation_kind, result.dependent_count}
    end)
  end

  defp assert_fallback_plan!(%Plan{} = plan) do
    stable_ids = MapSet.new(Enum.map(plan.fallback, & &1.stable_id))
    expected_ids = @expected_outcomes |> Map.keys() |> MapSet.new()

    if stable_ids != expected_ids do
      raise "fallback stable IDs mismatch: expected #{inspect(expected_ids)}, got #{inspect(stable_ids)}"
    end

    if length(plan.fallback) != 6 do
      raise "fallback plan mismatch: expected 6 mutants, got #{length(plan.fallback)}"
    end
  end

  defp assert_default_attribute_skip!(oracle) do
    plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    attribute_skips =
      Enum.filter(
        plan.skipped,
        &(&1.file == "lib/attrs.ex" and &1.syntactic_name == :some_const and
            &1.reason == :attribute_engine_disabled)
      )

    if length(attribute_skips) != 1 do
      raise "default plan expected one attrs.ex @some_const attribute_engine_disabled skip"
    end
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
