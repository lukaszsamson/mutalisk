defmodule Mut.TestSelection.ClauseHeadMetadataTest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end half of finding 3: the pattern mutant the planner generates for
  `def value(0)` must carry enough metadata for test selection to widen it past
  exact-line coverage — `env_context: :match` plus the enclosing `{name, arity}`
  (previously `function: nil`, which left the selector with nothing to widen to).
  """

  alias Mut.CoverageOracle
  alias Mut.FixtureOracleHelper
  alias Mut.TestSelection.Coverage

  @root Path.expand("tmp/tests/clause_head_metadata")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(Path.join(@root, "lib"))

    File.write!(Path.join(@root, "lib/astra_pattern.ex"), """
    defmodule AstraPattern do
      def value(0), do: :zero
      def value(_), do: :other
    end
    """)

    on_exit(fn -> File.rm_rf!(@root) end)
    :ok
  end

  test "the generated clause-head literal mutant carries match context and its function" do
    plan =
      Mut.Orchestrator.plan(@root, FixtureOracleHelper.oracle([]),
        files: ["lib/astra_pattern.ex"]
      )

    mutant =
      Enum.find(plan.schema ++ plan.fallback, fn mutant ->
        mutant.env_context == :match and mutant.line == 2
      end)

    assert mutant, "expected a pattern-position literal mutant on the `value(0)` clause head"
    assert mutant.function == {:value, 1}
    assert mutant.module == AstraPattern

    # With that metadata the selector reaches the killing test: :cover reports
    # line 2 only for zero_test and line 3 only for one_test, but the mutation
    # reroutes `value(0)` to the second clause, so one_test is the killer.
    oracle = %CoverageOracle{
      by_line: %{
        {"lib/astra_pattern.ex", 2} => MapSet.new([{:file, "test/zero_test.exs"}]),
        {"lib/astra_pattern.ex", 3} => MapSet.new([{:file, "test/one_test.exs"}])
      },
      by_function: %{
        {AstraPattern, :value, 1} =>
          MapSet.new([{:file, "test/zero_test.exs"}, {:file, "test/one_test.exs"}])
      }
    }

    selection = Coverage.for_plan(plan, oracle, %{})

    assert "test/one_test.exs" in selection[mutant.stable_id].test_files
  end
end
