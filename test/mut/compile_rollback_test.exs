defmodule Mut.CompileRollbackTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.CompileRollback
  alias Mut.SchemaPlacer.PlacementMap

  test "diagnostic_anchors parses compile errors and warnings" do
    output = """
    ** (CompileError) lib/foo.ex:5: undefined function x/0
    lib/bar.ex:7:12: warning: unused variable y
    stack line without anchor
    """

    assert CompileRollback.diagnostic_anchors(output) == [
             %{
               file: "lib/foo.ex",
               line: 5,
               diagnostic: "** (CompileError) lib/foo.ex:5: undefined function x/0"
             },
             %{
               file: "lib/bar.ex",
               line: 7,
               diagnostic: "lib/bar.ex:7:12: warning: unused variable y"
             }
           ]
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
end
