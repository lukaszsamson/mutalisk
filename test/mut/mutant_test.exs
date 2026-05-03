defmodule Mut.MutantTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    mutant = %Mut.Mutant{
      id: 1,
      stable_id: "abc123",
      engine: :schema,
      mutator: Mut.Mutator.Arithmetic,
      mutator_name: "Arithmetic",
      file: "lib/example.ex",
      line: 1,
      original_ast: {:+, [], [1, 2]},
      mutated_ast: {:-, [], [1, 2]},
      description: "replace + with -"
    }

    assert %Mut.Mutant{} = mutant
    assert mutant.status == :pending
    assert mutant.source_patch == nil
    assert mutant.skip_reason == nil

    assert_raise ArgumentError, fn -> struct!(Mut.Mutant, []) end
  end

  test "typespec accepts constructed values" do
    mutant = mutant(:killed)

    assert mutant.id == 1
    assert mutant.stable_id == "abc123"
    assert mutant.engine == :fallback
    assert mutant.mutator == Mut.Mutator.Arithmetic
    assert mutant.mutator_name == "Arithmetic"
    assert mutant.file == "lib/example.ex"
    assert mutant.line == 1
    assert mutant.column == 3
    assert mutant.span == {1, 3, 1, 8}
    assert mutant.module == Example
    assert mutant.function == {:sum, 2}
    assert mutant.original_ast == {:+, [], [1, 2]}
    assert mutant.mutated_ast == {:-, [], [1, 2]}
    assert %Mut.SourcePatch{} = mutant.source_patch
    assert mutant.original_source == "1 + 2"
    assert mutant.mutated_source == "1 - 2"
    assert mutant.description == "replace + with -"
    assert mutant.status == :killed
    assert mutant.skip_reason == :unsupported_dispatch
    assert mutant.covering_tests == ["test/example_test.exs"]
    assert mutant.killing_test == "test/example_test.exs"
    assert mutant.duration_ms == 12
    assert mutant.compile_error == %{message: "boom"}
  end

  test "status type includes all result classification atoms" do
    for status <- [:pending, :killed, :survived, :timeout, :invalid, :skipped, :error] do
      assert %Mut.Mutant{status: ^status} = mutant(status)
    end
  end

  test "Jason round-trip has expected keys and excludes AST fields" do
    json = Jason.encode!(jsonable_mutant())
    decoded = Jason.decode!(json)
    encoded_again = Jason.encode!(decoded)

    assert decoded |> Map.keys() |> Enum.sort() ==
             ~w(column compile_error covering_tests description duration_ms engine file function id killing_test line module mutated_source mutator mutator_name original_source skip_reason source_patch span stable_id status)

    refute Map.has_key?(decoded, "original_ast")
    refute Map.has_key?(decoded, "mutated_ast")
    refute String.contains?(encoded_again, "original_ast")
    refute String.contains?(encoded_again, "mutated_ast")
  end

  @spec mutant(Mut.Mutant.status()) :: Mut.Mutant.t()
  defp mutant(status) do
    %Mut.Mutant{
      id: 1,
      stable_id: "abc123",
      engine: :fallback,
      mutator: Mut.Mutator.Arithmetic,
      mutator_name: "Arithmetic",
      file: "lib/example.ex",
      line: 1,
      column: 3,
      span: {1, 3, 1, 8},
      module: Example,
      function: {:sum, 2},
      original_ast: {:+, [], [1, 2]},
      mutated_ast: {:-, [], [1, 2]},
      source_patch: %Mut.SourcePatch{
        file: "lib/example.ex",
        start_byte: 2,
        end_byte: 3,
        start_line: 1,
        start_column: 3,
        end_line: 1,
        end_column: 4,
        original: "+",
        replacement: "-"
      },
      original_source: "1 + 2",
      mutated_source: "1 - 2",
      description: "replace + with -",
      status: status,
      skip_reason: :unsupported_dispatch,
      covering_tests: ["test/example_test.exs"],
      killing_test: "test/example_test.exs",
      duration_ms: 12,
      compile_error: %{message: "boom"}
    }
  end

  @spec jsonable_mutant() :: Mut.Mutant.t()
  defp jsonable_mutant do
    %{mutant(:survived) | span: nil, function: nil}
  end
end
