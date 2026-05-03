defmodule Mix.Tasks.Mut.TestFallback do
  @moduledoc "Integration: run M10 fallback worker against the demo_app fixture."
  use Mix.Task

  alias Mut.Mutant
  alias Mut.Plan

  @shortdoc "Runs fallback worker integration against demo_app"

  @fixture_root Path.expand("test/fixtures/demo_app")
  @fixture_test_paths [Path.join(@fixture_root, "test")]
  @concurrency 1
  @timeout_ms 15_000

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    started = System.monotonic_time(:millisecond)

    {:ok, oracle} = Mut.OracleBuild.run(@fixture_root, run_id: "m10-oracle", force: true)
    schema_plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    {:ok, schema_result} =
      Mut.SchemaBuild.build(schema_plan,
        user_project_root: @fixture_root,
        run_id: "m10-schema",
        force: true,
        keep: true
      )

    fallback_plan = fallback_plan()

    {:ok, pool} =
      Mut.Sandbox.create_pool(schema_result, @concurrency, run_id: "m10-fallback", force: true)

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
    Enum.reduce(plan.fallback, {[], pool}, fn mutant, {results, pool} ->
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
    expected_counts = %{killed: 2, survived: 1}

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

  defp expected(%{mutation_kind: :boundary}), do: :survived
  defp expected(%{mutation_kind: :negation}), do: :killed
  defp expected(%{mutation_kind: :type_test}), do: :killed

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

  defp fallback_plan do
    source = File.read!(Path.join(@fixture_root, "lib/guards.ex"))

    %Plan{schema: [], fallback: fallback_mutants(source), skipped: []}
    |> Plan.finalize()
  end

  defp fallback_mutants(source) do
    [
      fallback_mutant(source, "boundary >=", "x > 0", quote(do: x >= 0), :boundary),
      fallback_mutant(source, "negation <=", "x > 0", quote(do: x <= 0), :negation),
      fallback_mutant(
        source,
        "type-test is_float",
        "is_integer(x)",
        quote(do: is_float(x)),
        :type_test
      )
    ]
  end

  defp fallback_mutant(source, description, original, mutated_ast, mutation_kind) do
    {start_byte, length} = :binary.match(source, original)
    end_byte = start_byte + length
    {line, column} = line_column(source, start_byte)
    {end_line, end_column} = line_column(source, end_byte)

    %Mutant{
      id: 0,
      stable_id: "",
      engine: :fallback,
      mutator: __MODULE__,
      mutator_name: "fallback_fixture",
      mutation_kind: mutation_kind,
      stable_id_kind: Atom.to_string(mutation_kind),
      original_dispatch: "guard:#{original}",
      ast_path_hash: nil,
      start_byte: start_byte,
      end_byte: end_byte,
      file: "lib/guards.ex",
      line: line,
      column: column,
      span: {line, column, end_line, end_column},
      module: Guards,
      function: {:positive?, 1},
      original_ast: original_ast(original),
      mutated_ast: mutated_ast,
      source_patch: nil,
      original_source: original,
      mutated_source: nil,
      description: description,
      status: :pending,
      skip_reason: nil,
      covering_tests: nil,
      killing_test: nil,
      duration_ms: nil,
      compile_error: nil
    }
  end

  defp original_ast("x > 0"), do: quote(do: x > 0)
  defp original_ast("is_integer(x)"), do: quote(do: is_integer(x))

  defp line_column(source, byte_offset) do
    before = binary_part(source, 0, byte_offset)
    lines = String.split(before, "\n")
    line = length(lines)
    column = List.last(lines) |> String.length() |> Kernel.+(1)
    {line, column}
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
