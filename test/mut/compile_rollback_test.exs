defmodule Mut.CompileRollbackTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.CompileRollback
  alias Mut.SchemaPlacer.PlacementMap

  test "diagnostic_anchors anchors on errors but NOT warnings (R10)" do
    output = """
    ** (CompileError) lib/foo.ex:5: undefined function x/0
    lib/bar.ex:7:12: warning: unused variable y
    stack line without anchor
    """

    # The warning line must NOT produce an anchor — invalidating the mutant on
    # bar.ex:7 (which only warned) when foo.ex:5 caused the error is the R10 bug.
    assert CompileRollback.diagnostic_anchors(output) == [
             %{
               file: "lib/foo.ex",
               line: 5,
               diagnostic: "** (CompileError) lib/foo.ex:5: undefined function x/0"
             }
           ]
  end

  test "diagnostic_anchors anchors a multi-line error block, skips a warning block (R10)" do
    output = """
    warning: variable "y" is unused
      │
      7 │   y = compute()
      │
      └─ lib/bar.ex:7:3

    error: undefined function x/0
      │
      5 │   x()
      │
      └─ lib/foo.ex:5:3
    """

    anchors = CompileRollback.diagnostic_anchors(output)
    assert Enum.any?(anchors, &(&1.file == "lib/foo.ex" and &1.line == 5))
    refute Enum.any?(anchors, &(&1.file == "lib/bar.ex"))
  end

  test "locate_mutants returns innermost matching range" do
    map = %PlacementMap{
      file: "lib/foo.ex",
      entries: [
        %{start_line: 1, end_line: 20, column: 1, mut_ids: [1]},
        %{start_line: 5, end_line: 8, column: 5, mut_ids: [2, 3]}
      ]
    }

    assert CompileRollback.locate_mutants(map, 6) == {:ok, [2, 3]}
    assert CompileRollback.locate_mutants(map, 10) == {:ok, [1]}
    assert CompileRollback.locate_mutants(map, 21) == :not_found
  end

  test "locate_mutants prefers a single mutant arm over an aggregate same-site range" do
    map = %PlacementMap{
      file: "lib/foo.ex",
      entries: [
        %{start_line: 10, end_line: 10, column: 5, mut_ids: [1, 2]},
        %{start_line: 10, end_line: 10, column: 15, mut_ids: [2]}
      ]
    }

    assert CompileRollback.locate_mutants(map, 10) == {:ok, [2]}
  end
end
