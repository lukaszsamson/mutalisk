defmodule Mut.StableIdTest do
  use ExUnit.Case, async: true

  @moduledoc false

  @input %{
    relative_file_path: "lib/example.ex",
    start_byte: 10,
    end_byte: 15,
    mutator_name: "Arithmetic",
    original_dispatch: "Kernel.+/2",
    mutation_kind: :arithmetic_op
  }

  test "same input produces the same hash" do
    assert Mut.StableId.compute(@input) == Mut.StableId.compute(@input)
  end

  test "different mutation kind produces a different hash" do
    assert Mut.StableId.compute(@input) !=
             Mut.StableId.compute(%{@input | mutation_kind: :comparison_boundary})
  end

  test "different original dispatch produces a different hash" do
    assert Mut.StableId.compute(@input) !=
             Mut.StableId.compute(%{@input | original_dispatch: "Kernel.-/2"})
  end

  test "hash is lowercase 32-character hex" do
    id = Mut.StableId.compute(@input)

    assert id =~ ~r/\A[0-9a-f]{32}\z/
  end

  test "nil byte offsets fall back to ast path hash and source snippet" do
    input =
      @input
      |> Map.merge(%{start_byte: nil, end_byte: nil})
      |> Map.put(:ast_path_hash, "abc123")
      |> Map.put(:original_source, "a + b")

    assert Mut.StableId.compute(input) == Mut.StableId.compute(input)
    assert Mut.StableId.compute(input) != Mut.StableId.compute(%{input | ast_path_hash: "def456"})

    assert Mut.StableId.compute(input) !=
             Mut.StableId.compute(%{input | original_source: "a - b"})
  end
end
