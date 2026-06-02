defmodule Mut.History.Reuse do
  @moduledoc """
  M106: the reuse decision. For one planned mutant, decide whether a stored
  verdict can be adopted (skip execution) or the mutant must execute.

  Conservative by mandate ("incorrect reuse is worse than a slow run"): reuse
  only on an **exact** digest match per the mutant's stored status (M104 §3).
  Any missing entry, digest mismatch, status mismatch, or — under `--since` — a
  changed source file → `:execute`.
  """

  alias Mut.Mutant

  @typedoc "Digests computed for the mutant in the *current* run."
  @type current :: %{
          source_digest: String.t(),
          selected_tests_digest: String.t(),
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

  defp reusable?(stored, current) do
    stored["source_digest"] == current.source_digest and
      stored["selected_tests_digest"] == current.selected_tests_digest and
      timeout_ok?(stored, current)
  end

  # Timeout verdicts additionally require the timeout budget unchanged; other
  # statuses are timeout-budget-independent.
  defp timeout_ok?(%{"status" => "timeout"} = stored, current),
    do: stored["test_timeout_ms"] == current.test_timeout_ms

  defp timeout_ok?(_stored, _current), do: true
end
