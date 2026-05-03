defmodule Mut.FallbackFixture do
  @moduledoc false

  alias Mut.Mutant
  alias Mut.Plan

  @fixture_root Path.expand("test/fixtures/demo_app")

  @spec plan() :: Plan.t()
  def plan do
    source = File.read!(Path.join(@fixture_root, "lib/guards.ex"))

    %Plan{schema: [], fallback: mutants(source), skipped: []}
    |> Plan.finalize()
  end

  @spec mutants(String.t()) :: [Mutant.t()]
  def mutants(source_text) when is_binary(source_text) do
    [
      guard_mutant(source_text, "boundary >=", "x > 0", quote(do: x >= 0), :boundary),
      guard_mutant(source_text, "negation <=", "x > 0", quote(do: x <= 0), :negation),
      guard_mutant(
        source_text,
        "type-test is_float",
        "is_integer(x)",
        quote(do: is_float(x)),
        :type_test
      )
    ]
  end

  defp guard_mutant(source_text, description, original, mutated_ast, mutation_kind) do
    {start_byte, length} = :binary.match(source_text, original)
    end_byte = start_byte + length
    {line, column} = line_column(source_text, start_byte)
    {end_line, end_column} = line_column(source_text, end_byte)

    %Mutant{
      id: 0,
      stable_id: "",
      engine: :fallback,
      mutator: __MODULE__,
      mutator_name: "fallback_fixture",
      mutation_kind: mutation_kind,
      stable_id_kind: Atom.to_string(mutation_kind),
      original_dispatch: "guard:#{original}",
      ast_path_hash: nil,
      start_byte: start_byte,
      end_byte: end_byte,
      file: "lib/guards.ex",
      line: line,
      column: column,
      span: {line, column, end_line, end_column},
      module: Guards,
      function: {:positive?, 1},
      original_ast: original_ast(original),
      mutated_ast: mutated_ast,
      source_patch: nil,
      original_source: original,
      mutated_source: nil,
      description: description,
      status: :pending,
      skip_reason: nil,
      covering_tests: nil,
      killing_test: nil,
      duration_ms: nil,
      compile_error: nil
    }
  end

  defp original_ast("x > 0"), do: quote(do: x > 0)
  defp original_ast("is_integer(x)"), do: quote(do: is_integer(x))

  defp line_column(source_text, byte_offset) do
    before = binary_part(source_text, 0, byte_offset)
    lines = String.split(before, "\n")
    line = length(lines)
    column = List.last(lines) |> String.length() |> Kernel.+(1)
    {line, column}
  end
end
