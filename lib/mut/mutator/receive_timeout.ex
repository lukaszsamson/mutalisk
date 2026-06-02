defmodule Mut.Mutator.ReceiveTimeout do
  @moduledoc """
  M94 niche mutator — mutate the `after` clause of a `receive` block.
  In `receive do … after t -> body end`, three variants:

    1. **`t` -> `0`**: immediate timeout. The `body` runs at once,
       bypassing the message-handler clauses entirely.
    2. **`t` -> `:infinity`**: never times out. The body becomes
       unreachable; the receive waits forever for a matching message
       (typically observed as a hung test → killed).
    3. **drop `after`**: remove the `after` clause from the receive
       altogether. Behaviour matches variant 2 (no timeout), but
       structurally distinct — exercises the path where the `body`
       isn't even compiled into the receive.

  All three are opt-in via the `:receive_timeout` target. Fallback-
  routed (whole-receive span).

  Hazard discipline:

    * Only triggers when the receive **has** an `after` clause.
      Receive blocks without `after` are not mutated here (there's
      nothing to mutate; M90's ClauseDelete extension handles the
      message-handler `:do` clauses).
    * Variant 1 (`0`) and variant 3 (drop after) overlap semantically
      when the receive's `do` body alone is sufficient. The signal
      mostly lands on tests that distinguish the timeout vs. the
      message-handler arms — exactly the value of mutating the
      timeout. The M62 gate quantifies the noise.

  *Out of scope:* mutating the timeout `body` expression (would
  belong to a body-statement mutator); mutating the
  message-handler clauses (M87 ClauseDelete extension covers them
  via the `:do` section).
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :receive_timeout

  @impl true
  def name, do: "ReceiveTimeout"

  @impl true
  def description, do: "Mutate receive `after` timeout (0 / :infinity / drop)."

  @impl true
  def targets, do: [:receive_timeout]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and receive_with_after?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{syntactic_name: :receive_timeout}, _site), do: true
  def compatible?(_candidate, _site), do: false

  defp receive_with_after?({:receive, _meta, [args]}) when is_list(args) do
    case Keyword.get(args, :after) do
      [{:->, _, [[_t], _body]} | _] -> true
      _ -> false
    end
  end

  defp receive_with_after?(_node), do: false

  defp build_mutations({:receive, meta, [args]} = node) do
    [{:->, arrow_meta, [[_t], body]} | rest_after] = Keyword.fetch!(args, :after)
    base_clauses = Keyword.delete(args, :after)

    swap = fn new_t ->
      new_after = [{:->, arrow_meta, [[new_t], body]} | rest_after]
      new_args = Keyword.put(args, :after, new_after)

      %Mutation{
        original_ast: node,
        mutated_ast: {:receive, meta, [new_args]},
        description: "set receive `after` to #{inspect(new_t)}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{change: {:set_timeout, new_t}}
      }
    end

    mutations = [swap.(0), swap.(:infinity)]

    if Keyword.has_key?(args, :do) do
      drop = %Mutation{
        original_ast: node,
        mutated_ast: {:receive, meta, [base_clauses]},
        description: "drop receive `after` clause",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{change: :drop_after}
      }

      mutations ++ [drop]
    else
      mutations
    end
  end
end
