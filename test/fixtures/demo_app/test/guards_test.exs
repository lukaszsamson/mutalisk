defmodule GuardsTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # Intentionally weak: future guard boundary mutants can survive here.
  test "positive? accepts positive integers" do
    assert Guards.positive?(5) == true
  end
end
