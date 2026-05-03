defmodule Mut.FallbackPatchTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.FallbackPatch
  alias Mut.Mutant
  alias Mut.SourcePatch

  test "render builds a byte-range patch from a mutant span" do
    source = "def positive?(x) when is_integer(x) and x > 0, do: true\n"
    start_byte = :binary.match(source, "x > 0") |> elem(0)
    end_byte = start_byte + byte_size("x > 0")

    mutant = mutant(start_byte: start_byte, end_byte: end_byte, mutated_ast: quote(do: x >= 0))

    assert {:ok, %SourcePatch{} = patch} = FallbackPatch.render(mutant, source)
    assert patch.file == "lib/guards.ex"
    assert patch.start_byte == start_byte
    assert patch.end_byte == end_byte
    assert patch.original == "x > 0"
    assert patch.replacement == "x >= 0"
    assert patch.start_line == 1
    assert patch.start_column == 41
    assert patch.end_line == 1
    assert patch.end_column == 46
  end

  test "render refuses mutants without precise byte spans" do
    assert FallbackPatch.render(mutant(start_byte: nil), "x > 0") ==
             {:error, :missing_source_span}

    assert FallbackPatch.render(mutant(end_byte: nil), "x > 0") ==
             {:error, :missing_source_span}
  end

  test "apply splices bytes without treating UTF-8 as character offsets" do
    root = Path.expand("tmp/tests/fallback_patch/utf8")
    file = Path.join(root, "lib/example.ex")
    File.rm_rf!(root)
    File.mkdir_p!(Path.dirname(file))

    source = "pre λ x > 0 post"
    File.write!(file, source)

    start_byte = :binary.match(source, "x > 0") |> elem(0)

    patch = %SourcePatch{
      file: "lib/example.ex",
      start_byte: start_byte,
      end_byte: start_byte + byte_size("x > 0"),
      start_line: 1,
      original: "x > 0",
      replacement: "x <= 0"
    }

    assert :ok = FallbackPatch.apply(patch, root)
    assert File.read!(file) == "pre λ x <= 0 post"
  end

  defp mutant(attrs) do
    defaults = [
      id: 1,
      stable_id: "stable",
      engine: :fallback,
      mutator: __MODULE__,
      mutator_name: "test",
      file: "lib/guards.ex",
      line: 1,
      column: 41,
      span: {1, 41, 1, 46},
      start_byte: 0,
      end_byte: 5,
      original_ast: quote(do: x > 0),
      mutated_ast: quote(do: x >= 0),
      description: "test fallback patch"
    ]

    struct!(Mutant, Keyword.merge(defaults, attrs))
  end
end
