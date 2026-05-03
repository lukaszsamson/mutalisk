defmodule Mut.MutatorTest do
  use ExUnit.Case, async: true

  @moduledoc false

  defmodule StubMutator do
    @moduledoc false
    @behaviour Mut.Mutator

    @impl true
    def name, do: "Stub"

    @impl true
    def description, do: "stub mutator"

    @impl true
    def targets, do: [:dispatch]

    @impl true
    def applicable?(_ast, _context), do: true

    @impl true
    def mutate(ast, _context) do
      [
        %Mut.Mutation{
          original_ast: ast,
          mutated_ast: ast,
          description: "identity",
          mutation_kind: :identity,
          guard_safe?: true
        }
      ]
    end

    @impl true
    def equivalent?(_mutation), do: false
  end

  test "exports the expected callbacks" do
    callbacks = Mut.Mutator.behaviour_info(:callbacks)

    assert Enum.sort(callbacks) ==
             Enum.sort(
               name: 0,
               description: 0,
               targets: 0,
               applicable?: 2,
               mutate: 2,
               equivalent?: 1
             )
  end

  test "stub mutator implements the behaviour" do
    context = %Mut.Context{
      file: "lib/example.ex",
      ast_path: [],
      ast_path_hash: "hash",
      engine: :schema
    }

    assert StubMutator.name() == "Stub"
    assert StubMutator.description() == "stub mutator"
    assert StubMutator.targets() == [:dispatch]
    assert StubMutator.applicable?(1, context)
    assert [%Mut.Mutation{} = mutation] = StubMutator.mutate(1, context)
    refute StubMutator.equivalent?(mutation)
  end
end
