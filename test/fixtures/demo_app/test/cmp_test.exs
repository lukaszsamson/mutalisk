defmodule CmpTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # M8 expects comparison boundary and negation mutants to be killed.
  test "ordered? covers the <= boundary" do
    assert Cmp.ordered?(1, 2) == true
    assert Cmp.ordered?(2, 2) == true
    assert Cmp.ordered?(3, 2) == false
  end

  test "distinct_direction? covers both directions" do
    assert Cmp.distinct_direction?(1, 2) == true
    assert Cmp.distinct_direction?(2, 1) == true
  end
end
