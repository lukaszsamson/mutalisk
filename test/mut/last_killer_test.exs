defmodule Mut.LastKillerTest do
  use ExUnit.Case, async: true

  test "records and looks up the last killing test by module" do
    {:ok, killer} = Mut.LastKiller.start_link([])

    assert Mut.LastKiller.lookup(killer, Sample.Module) == nil
    assert :ok = Mut.LastKiller.record_kill(killer, Sample.Module, "test/sample_test.exs")
    assert Mut.LastKiller.lookup(killer, Sample.Module) == "test/sample_test.exs"
    assert Mut.LastKiller.snapshot(killer) == %{Sample.Module => "test/sample_test.exs"}
  end

  test "state is isolated per started process" do
    {:ok, first} = Mut.LastKiller.start_link([])
    {:ok, second} = Mut.LastKiller.start_link([])

    Mut.LastKiller.record_kill(first, Sample.Module, "test/first_test.exs")

    assert Mut.LastKiller.lookup(first, Sample.Module) == "test/first_test.exs"
    assert Mut.LastKiller.lookup(second, Sample.Module) == nil
  end
end
