defmodule Mut.SourceSpanTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    span = %Mut.SourceSpan{
      file: "lib/example.ex",
      start_line: 1,
      start_byte: 0,
      end_byte: 4
    }

    assert %Mut.SourceSpan{} = span
    assert span.start_column == nil
    assert span.end_line == nil
    assert span.end_column == nil

    assert_raise ArgumentError, fn -> struct!(Mut.SourceSpan, []) end
  end

  test "typespec accepts constructed values" do
    span = source_span()

    assert span.file == "lib/example.ex"
    assert span.start_line == 1
    assert span.start_column == 2
    assert span.end_line == 1
    assert span.end_column == 6
    assert span.start_byte == 0
    assert span.end_byte == 4
  end

  test "JSON round-trip has expected keys" do
    keys =
      source_span()
      |> Mut.JSON.encode!()
      |> Mut.JSON.decode!()
      |> Map.keys()
      |> Enum.sort()

    assert keys == ~w(end_byte end_column end_line file start_byte start_column start_line)
  end

  @spec source_span() :: Mut.SourceSpan.t()
  defp source_span do
    %Mut.SourceSpan{
      file: "lib/example.ex",
      start_line: 1,
      start_column: 2,
      end_line: 1,
      end_column: 6,
      start_byte: 0,
      end_byte: 4
    }
  end
end
