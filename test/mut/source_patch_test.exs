defmodule Mut.SourcePatchTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    patch = %Mut.SourcePatch{
      file: "lib/example.ex",
      start_byte: 10,
      end_byte: 11,
      start_line: 2,
      original: "+",
      replacement: "-"
    }

    assert %Mut.SourcePatch{} = patch
    assert patch.start_column == nil
    assert patch.end_line == nil
    assert patch.end_column == nil

    assert_raise ArgumentError, fn -> struct!(Mut.SourcePatch, []) end
  end

  test "typespec accepts constructed values" do
    patch = source_patch()

    assert patch.file == "lib/example.ex"
    assert patch.start_byte == 10
    assert patch.end_byte == 11
    assert patch.start_line == 2
    assert patch.start_column == 5
    assert patch.end_line == 2
    assert patch.end_column == 6
    assert patch.original == "+"
    assert patch.replacement == "-"
  end

  test "Jason round-trip has expected keys" do
    keys =
      source_patch()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Map.keys()
      |> Enum.sort()

    assert keys ==
             ~w(end_byte end_column end_line file original replacement start_byte start_column start_line)
  end

  @spec source_patch() :: Mut.SourcePatch.t()
  defp source_patch do
    %Mut.SourcePatch{
      file: "lib/example.ex",
      start_byte: 10,
      end_byte: 11,
      start_line: 2,
      start_column: 5,
      end_line: 2,
      end_column: 6,
      original: "+",
      replacement: "-"
    }
  end
end
