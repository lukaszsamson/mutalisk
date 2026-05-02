defmodule MutaliskTest do
  use ExUnit.Case
  doctest Mutalisk

  test "greets the world" do
    assert Mutalisk.hello() == :world
  end
end
