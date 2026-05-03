defmodule Mut.MutationTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    mutation = %Mut.Mutation{
      original_ast: {:+, [], [1, 2]},
      mutated_ast: {:-, [], [1, 2]},
      description: "replace + with -",
      mutation_kind: :operator_replacement,
      guard_safe?: true
    }

    assert %Mut.Mutation{} = mutation
    assert mutation.metadata == %{}

    assert_raise ArgumentError, fn -> struct!(Mut.Mutation, []) end
  end

  test "typespec accepts constructed values" do
    mutation = mutation()

    assert mutation.original_ast == {:+, [], [1, 2]}
    assert mutation.mutated_ast == {:-, [], [1, 2]}
    assert mutation.description == "replace + with -"
    assert mutation.mutation_kind == :operator_replacement
    assert mutation.guard_safe? == true
    assert mutation.metadata == %{operator: :+}
  end

  @spec mutation() :: Mut.Mutation.t()
  defp mutation do
    %Mut.Mutation{
      original_ast: {:+, [], [1, 2]},
      mutated_ast: {:-, [], [1, 2]},
      description: "replace + with -",
      mutation_kind: :operator_replacement,
      guard_safe?: true,
      metadata: %{operator: :+}
    }
  end
end
