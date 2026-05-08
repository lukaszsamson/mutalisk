defmodule LiteralsTest do
  use ExUnit.Case, async: true

  test "magic returns 42" do
    assert Literals.magic() == 42
  end

  test "origin returns 0" do
    assert Literals.origin() == 0
  end

  test "feature_enabled? returns true" do
    assert Literals.feature_enabled?() == true
  end
end
