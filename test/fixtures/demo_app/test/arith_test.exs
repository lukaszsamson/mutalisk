defmodule ArithTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # M8 expects arithmetic score and integer_parts mutants to be killed.
  test "score combines sum and difference" do
    assert Arith.score(3, 5) == -16
    assert Arith.score(2, 2) == 0
  end

  test "integer_parts returns quotient and remainder" do
    assert Arith.integer_parts(7, 3) == {2, 1}
  end
end
