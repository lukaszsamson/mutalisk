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
end
