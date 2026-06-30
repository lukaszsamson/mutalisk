defmodule Mut.RuntimeTest do
  use ExUnit.Case, async: true

  @moduledoc false

  setup do
    Mut.Runtime.clear()
    :ok
  end

  test "round-trips the active mutant" do
    assert Mut.Runtime.get_active() == 0
    assert Mut.Runtime.set_active(42) == :ok
    assert Mut.Runtime.get_active() == 42
    assert Mut.Runtime.clear() == :ok
    assert Mut.Runtime.get_active() == 0
  end

  test "public active mutant helpers are VM-global across processes" do
    assert Mutalisk.set_active(7) == :ok

    parent = self()

    spawn(fn ->
      send(parent, {:active, Mutalisk.get_active()})
    end)

    assert_receive {:active, 7}

    assert Mutalisk.clear() == :ok
    assert Mutalisk.get_active() == 0
  end

  test "rejects invalid active mutant ids with a useful error" do
    for id <- [-1, "1", 1.0] do
      assert_raise ArgumentError, ~r/non-negative integer/, fn ->
        Mut.Runtime.set_active(id)
      end
    end
  end
end
