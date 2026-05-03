defmodule Mut.Mutator.Test.AlwaysWrong do
  @moduledoc false
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @binary_ops ~w(+ - * / div rem < <= > >= == != and or && ||)a

  @impl true
  def name, do: "AlwaysWrong"

  @impl true
  def description, do: "Emit non-compiling AST for rollback tests."

  @impl true
  def targets, do: [:dispatch]

  @impl true
  def applicable?({op, _meta, args}, %Mut.Context{}) when op in @binary_ops and length(args) == 2,
    do: true

  def applicable?(_node, %Mut.Context{}), do: false

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx) do
      [
        %Mutation{
          original_ast: node,
          mutated_ast: {:undefined_remote_atom, [], [node]},
          description: "emit undefined remote atom call",
          mutation_kind: :always_wrong,
          guard_safe?: false,
          metadata: %{replacement: :undefined_remote_atom}
        }
      ]
    else
      []
    end
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t()) :: boolean
  def compatible?(%AstCandidate{syntactic_name: name, syntactic_arity: 2}, %DispatchSite{})
      when name in @binary_ops,
      do: true

  def compatible?(%AstCandidate{}, %DispatchSite{}), do: false
end
