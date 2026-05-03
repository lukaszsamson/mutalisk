defmodule Mut.SourceParseTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "parses a valid file and returns the source text" do
    path = tmp_file("valid.ex", "defmodule ValidParse do\n  def ok, do: :ok\nend\n")

    assert {:ok, {{:defmodule, _meta, _args}, source}} = Mut.SourceParse.parse(path)
    assert source == File.read!(path)
  end

  test "returns tagged parse errors" do
    path = tmp_file("invalid.ex", "defmodule InvalidParse do\n  def broken(\nend\n")

    assert {:error, {^path, line, message}} = Mut.SourceParse.parse(path)
    assert is_integer(line)
    assert is_binary(message)
  end

  test "honors columns and token metadata" do
    source = "defmodule TokenMeta do\n  def ok, do: :ok\nend\n"

    assert {:ok, {:defmodule, meta, [_module, [do: {:def, def_meta, _args}]]}} =
             Mut.SourceParse.parse_string(source, "token_meta.ex")

    assert Keyword.fetch!(meta, :column) == 1
    assert Keyword.has_key?(meta, :end)
    assert Keyword.has_key?(def_meta, :end_of_expression)
  end

  defp tmp_file(name, contents) do
    path = Path.expand(Path.join(["tmp", "tests", "source_parse", name]))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
