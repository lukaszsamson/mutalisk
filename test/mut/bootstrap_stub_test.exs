defmodule Mut.BootstrapStubTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Bootstrap

  test "bootstrap role reads MUTALISK_ROLE" do
    previous = System.get_env("MUTALISK_ROLE")

    on_exit(fn -> restore_env(previous) end)

    for {value, role} <- [
          {"oracle", :oracle},
          {"schema", :schema},
          {"worker", :worker},
          {"fallback", :fallback}
        ] do
      System.put_env("MUTALISK_ROLE", value)
      assert Bootstrap.role() == role
    end

    System.delete_env("MUTALISK_ROLE")
    assert Bootstrap.role() == nil
  end

  defp restore_env(nil), do: System.delete_env("MUTALISK_ROLE")
  defp restore_env(value), do: System.put_env("MUTALISK_ROLE", value)
end
