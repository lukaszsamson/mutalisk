defmodule Mut.Mutator.PipelineDropStage do
  @moduledoc """
  M94 niche mutator — drop a middle stage from a `|>` chain. In
  `a |> f() |> g() |> h()`, dropping `g` yields `a |> f() |> h()` and
  is observable on any test that depends on what `g/1` does to the
  intermediate value.

  Aggressive hazard gating at candidate emission time, mirroring
  M81/M87's discipline:

    * **First stage skipped** — dropping the first stage means the
      input itself is dropped: `a |> f()` becomes `a` (no
      transformation applied), which is far closer to "noise"
      semantically (the test was about what `f` does to `a`; without
      `f` the value flows raw to the next stage). The plan calls this
      the "destroys the input" hazard.
    * **Last stage skipped** — dropping the last stage often yields a
      refactoring-equivalent (the upstream stages still ran; their
      result is just returned instead of being further transformed).
      Frequently equivalent under the test suite.
    * **Chains shorter than 3 stages** (i.e. < 4 flat-list elements
      counting the input) have no middle to drop — skipped at the
      collector.

  Fallback-routed: the candidate's `source_span` is the whole pipeline
  expression (leftmost input leaf -> rightmost call's `:closing`), the
  mutation re-renders the pipeline with the indexed stage removed, and
  `Mut.FallbackPatch` splices it back via `Macro.to_string` +
  `Code.format_string!`. Opt-in via the dedicated `:pipeline_drop`
  target (kept out of `@default_enabled_targets`).

  *Out of scope:* Pipeline-order swap (separate sub-shape); inserting
  a stage; mutating the input expression.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :pipeline_drop_stage

  @impl true
  def name, do: "PipelineDropStage"

  @impl true
  def description, do: "Drop a middle stage from a |> chain."

  @impl true
  def targets, do: [:pipeline_drop]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and pipeline_top?(node) and is_integer(stage_index(ctx))
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutation(node, stage_index(ctx)), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{syntactic_name: :pipeline_drop_stage}, _site), do: true
  def compatible?(_candidate, _site), do: false

  defp pipeline_top?({:|>, _meta, [_lhs, _rhs]}), do: true
  defp pipeline_top?(_node), do: false

  # The candidate's ast_path is
  # `[:pipeline_drop_stage, file, line, col, stage_index]` (see
  # `Mut.AstWalk.pipeline_drop_candidates`); the index is the last element.
  defp stage_index(%Mut.Context{ast_path: path}) when is_list(path) do
    case List.last(path) do
      i when is_integer(i) -> i
      _ -> nil
    end
  end

  defp stage_index(_ctx), do: nil

  defp build_mutation(node, index) do
    stages = flatten_pipeline(node)

    if index > 1 and index < length(stages) - 1 do
      new_stages = List.delete_at(stages, index)
      rebuilt = rebuild_pipeline(new_stages)

      [
        %Mutation{
          original_ast: node,
          mutated_ast: rebuilt,
          description: "drop pipeline stage #{index}",
          mutation_kind: @kind,
          guard_safe?: true,
          metadata: %{index: index}
        }
      ]
    else
      []
    end
  end

  # Flatten a `|>` chain into `[input, stage1, stage2, ..., stageN]`.
  defp flatten_pipeline({:|>, _meta, [lhs, rhs]}), do: flatten_pipeline(lhs) ++ [rhs]
  defp flatten_pipeline(input), do: [input]

  # Rebuild a flat `[input, s1, s2, ..., sN]` into a left-associative `|>` AST.
  defp rebuild_pipeline([single]), do: single

  defp rebuild_pipeline([input | rest]) do
    Enum.reduce(rest, input, fn stage, acc -> {:|>, [], [acc, stage]} end)
  end
end
