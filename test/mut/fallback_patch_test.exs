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

  test "M99 #2: EnvWalker span feeds the patcher byte-correctly on non-ASCII source" do
    # End-to-end span→patch chain on a line with a multi-byte char before the
    # literal: EnvWalker must compute a codepoint-correct byte span, and the
    # patcher must splice exactly that literal (no off-by-UTF-8-bytes drift).
    source = ~S'''
    defmodule M do
      def slogan, do: "café" <> "bar"
    end
    '''

    {:ok, ast} = Mut.EnvWalker.parse_string(source, "lib/m.ex")

    candidate =
      ast
      |> Mut.EnvWalker.collect_string_literal_candidates(file: "lib/m.ex", source: source)
      |> Enum.find(fn {c, _snap} ->
        span = c.source_span
        binary_part(source, span.start_byte, span.end_byte - span.start_byte) == ~s("bar")
      end)

    refute is_nil(candidate), "expected to find the \"bar\" literal after café"
    {c, _snap} = candidate
    span = c.source_span

    mutant =
      mutant(
        start_byte: span.start_byte,
        end_byte: span.end_byte,
        line: span.start_line,
        column: span.start_column,
        span: {span.start_line, span.start_column, span.end_line, span.end_column},
        original_ast: "bar",
        mutated_ast: ""
      )

    assert {:ok, %SourcePatch{} = patch} = FallbackPatch.render(mutant, source)
    # The spliced original is exactly the literal, not a byte-shifted slice.
    assert patch.original == ~s("bar")

    # Applying the patch produces correct mutated source (café preserved).
    root = Path.expand("tmp/tests/fallback_patch/m99_utf8")
    file = Path.join(root, "lib/m.ex")
    File.rm_rf!(root)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, source)
    patch = %{patch | file: "lib/m.ex"}
    :ok = FallbackPatch.apply(patch, root)

    assert File.read!(file) =~ ~s(def slogan, do: "café" <> "")
    File.rm_rf!(root)
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
