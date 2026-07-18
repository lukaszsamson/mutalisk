defmodule Mut.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc false

  setup_all do
    Application.stop(:mutalisk)

    on_exit(fn ->
      Application.ensure_all_started(:mutalisk)
    end)

    :ok
  end

  setup do
    previous = System.get_env("MUT_ACTIVE")

    on_exit(fn ->
      restore_env(previous)
      Mut.Runtime.clear()
    end)

    Mut.Runtime.clear()
    :ok
  end

  test "honors MUT_ACTIVE" do
    assert {:ok, pid} = start_with_env("42")
    assert pid != self()
    assert Process.alive?(pid)
    assert Mut.Runtime.get_active() == 42
    Supervisor.stop(pid)
  end

  test "trims MUT_ACTIVE before parsing" do
    assert {:ok, pid} = start_with_env(" 42 ")
    assert pid != self()
    assert Process.alive?(pid)
    assert Mut.Runtime.get_active() == 42
    Supervisor.stop(pid)
  end

  test "falls back to zero when MUT_ACTIVE is unset or empty" do
    for value <- [nil, ""] do
      assert {:ok, pid} = start_with_env(value)
      assert pid != self()
      assert Process.alive?(pid)
      assert Mut.Runtime.get_active() == 0
      Supervisor.stop(pid)
      Mut.Runtime.clear()
    end
  end

  test "warns when MUT_ACTIVE is invalid" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, pid} = start_with_env("not-an-id")
        assert Mut.Runtime.get_active() == 0
        Supervisor.stop(pid)
      end)

    assert output =~ "invalid MUT_ACTIVE"
    assert output =~ "using 0"
  end

  defp start_with_env(nil) do
    System.delete_env("MUT_ACTIVE")
    Mut.Application.start(:normal, [])
  end

  defp start_with_env(value) do
    System.put_env("MUT_ACTIVE", value)
    Mut.Application.start(:normal, [])
  end

  defp restore_env(nil), do: System.delete_env("MUT_ACTIVE")
  defp restore_env(value), do: System.put_env("MUT_ACTIVE", value)
end
