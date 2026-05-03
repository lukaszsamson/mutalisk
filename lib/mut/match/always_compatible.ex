defmodule Mut.Match.AlwaysCompatible do
  @moduledoc "M3 default oracle compatibility predicate."

  @behaviour Mut.Mutator

  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl Mut.Mutator
  def name, do: "AlwaysCompatible"

  @impl Mut.Mutator
  def description, do: "M3 stub: every candidate matches every site."

  @impl Mut.Mutator
  def targets, do: [:dispatch]

  @impl Mut.Mutator
  def applicable?(_node, _ctx), do: true

  @impl Mut.Mutator
  def mutate(_node, _ctx), do: []

  @impl Mut.Mutator
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t()) :: boolean
  def compatible?(%AstCandidate{} = candidate, %DispatchSite{} = site) do
    candidate.syntactic_name == site.resolved_name and
      candidate.syntactic_arity == site.resolved_arity
  end
end
