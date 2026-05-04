defmodule Mut.TestSelection.CoverageTest do
  use ExUnit.Case, async: true

  alias Mut.CoverageOracle
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.TestSelection.Coverage

  test "selects exact line coverage first" do
    plan = plan([mutant("exact", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{{"lib/sample.ex", 10} => MapSet.new([{:file, "test/exact_test.exs"}])},
      by_function: %{{Sample, :run, 1} => MapSet.new([{:file, "test/function_test.exs"}])}
    }

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["exact"] == %{test_files: ["test/exact_test.exs"], match_kind: :exact_line}
  end

  test "falls back to enclosing function coverage" do
    plan = plan([mutant("function", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_function: %{{Sample, :run, 1} => MapSet.new([{:file, "test/function_test.exs"}])}
    }

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["function"] == %{
             test_files: ["test/function_test.exs"],
             match_kind: :enclosing_function
           }
  end

  test "falls back to static selection" do
    plan = plan([mutant("static", "lib/sample.ex", 10, Sample, {:run, 1})])
    oracle = %CoverageOracle{}

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["static"] == %{
             test_files: ["test/static_test.exs"],
             match_kind: :static_fallback
           }
  end

  test "falls back to all tests as final safety net" do
    plan = plan([mutant("all", "lib/sample.ex", 10, Sample, {:run, 1})])
    oracle = %CoverageOracle{}

    result =
      Coverage.for_plan(plan, oracle, %{}, all_test_files: ["test/a_test.exs", "test/b_test.exs"])

    assert result["all"] == %{
             test_files: ["test/a_test.exs", "test/b_test.exs"],
             match_kind: :all_tests
           }
  end

  test "orders selected tests by last killer, convention, runtime, and path" do
    plan = plan([mutant("ordered", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{
        {"lib/sample.ex", 10} =>
          MapSet.new([
            {:file, "test/z_slow_test.exs"},
            {:file, "test/sample_test.exs"},
            {:file, "test/a_fast_test.exs"},
            {:file, "test/b_fast_test.exs"}
          ])
      },
      test_runtime_ms: %{
        {:file, "test/z_slow_test.exs"} => 5,
        {:file, "test/a_fast_test.exs"} => 10,
        {:file, "test/b_fast_test.exs"} => 10,
        {:file, "test/sample_test.exs"} => 999
      }
    }

    {:ok, killer} = Mut.LastKiller.start_link([])
    Mut.LastKiller.record_kill(killer, Sample, "test/z_slow_test.exs")

    result = Coverage.for_plan(plan, oracle, %{}, last_killer: killer)

    assert result["ordered"].test_files == [
             "test/z_slow_test.exs",
             "test/sample_test.exs",
             "test/a_fast_test.exs",
             "test/b_fast_test.exs"
           ]
  end

  defp plan(mutants), do: %Plan{schema: mutants, fallback: [], skipped: []}

  defp mutant(stable_id, file, line, module, function) do
    %Mutant{
      id: 1,
      stable_id: stable_id,
      engine: :schema,
      mutator: __MODULE__,
      mutator_name: "TestMutator",
      file: file,
      line: line,
      module: module,
      function: function,
      original_ast: quote(do: a + b),
      mutated_ast: quote(do: a - b),
      description: "replace + with -"
    }
  end
end
