defmodule Mut.History.Reuse do
  @moduledoc """
  M106: the reuse decision. For one planned mutant, decide whether a stored
  verdict can be adopted (skip execution) or the mutant must execute.

  Conservative by mandate ("incorrect reuse is worse than a slow run"): reuse
  only when **every** input that can affect the verdict is unchanged — the
  mutant's function source, its selected tests, the coarse project fingerprint
  (all source + config + deps), and the timeout budget (see `reusable?/2`). Any
  missing entry, any digest mismatch, or — under `--since` — a changed source
  file → `:execute`.
  """

  alias Mut.Mutant

  @typedoc "Digests computed for the mutant in the *current* run."
  @type current :: %{
          source_digest: String.t(),
          selected_tests_digest: String.t(),
          project_digest: String.t(),
          test_timeout_ms: pos_integer() | nil
        }

  @doc """
  Decide reuse for `mutant` against the loaded store `verdicts` (a
  `stable_id => entry` map) and the mutant's `current` digests.

  `file_changed?` is the `--since` gate: when the mutant's source file changed
  since the diff ref, always execute (defense in depth on top of the digest
  check).
  """
  @spec decide(Mutant.t(), map(), current(), boolean()) :: {:reuse, map()} | :execute
  def decide(mutant, verdicts, current, file_changed? \\ false)

  def decide(%Mutant{}, _verdicts, _current, true), do: :execute

  def decide(%Mutant{stable_id: stable_id}, verdicts, current, false) do
    case Map.get(verdicts, stable_id) do
      nil -> :execute
      stored -> if reusable?(stored, current), do: {:reuse, stored}, else: :execute
    end
  end

  # Reuse only when EVERY input that can affect the verdict is unchanged:
  #   * `source_digest` — the mutant's enclosing function (M104).
  #   * `selected_tests_digest` — the mutant's selected test files (M104).
  #   * `project_digest` — the coarse project fingerprint (M-review P1a): all
  #     `lib` source + test support/fixtures + config + `mix.lock`/`mix.exs`, so
  #     a change to a dependency of the mutated code or its tests invalidates
  #     reuse even though the per-mutant digests still match.
  #   * `test_timeout_ms` — the timeout budget, required for ALL statuses
  #     (M-review P1b): lowering it can turn a previously `survived` mutant into
  #     a `timeout` detection, so a budget change must invalidate every verdict,
  #     not only stored `"timeout"` ones.
  defp reusable?(stored, current) do
    stored["source_digest"] == current.source_digest and
      stored["selected_tests_digest"] == current.selected_tests_digest and
      stored["project_digest"] == current.project_digest and
      stored["test_timeout_ms"] == current.test_timeout_ms
  end
end
