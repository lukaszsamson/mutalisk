defmodule Mix.Tasks.Mut.E2eScoreTest do
  use ExUnit.Case, async: true

  @moduledoc """
  T38: `Mix.Tasks.Mut.E2e.score/1` divided by `killed + survived` with no
  guard, so a status map with neither key (every mutant errored/invalid/
  skipped, or none at all) crashed with a raw `ArithmeticError` instead of a
  diagnostic. Pinning it directly since the module is unit-testable — `score/1`
  is a pure function of the status-frequency map produced by `counts/1`.
  """

  alias Mix.Tasks.Mut.E2e

  test "returns nil instead of crashing when no mutant was scored" do
    assert E2e.score(%{}) == nil
    assert E2e.score(%{"Error" => 3, "Invalid" => 1}) == nil
  end

  test "computes the killed/(killed+survived) percentage otherwise" do
    assert E2e.score(%{"Killed" => 3, "Survived" => 1}) == 75.0
    assert E2e.score(%{"Killed" => 0, "Survived" => 4}) == 0.0
    assert E2e.score(%{"Killed" => 4, "Survived" => 0}) == 100.0
  end

  test "ignores Error/Invalid/Skipped counts in the denominator" do
    assert E2e.score(%{"Killed" => 1, "Survived" => 1, "Error" => 10, "Invalid" => 10}) == 50.0
  end
end
