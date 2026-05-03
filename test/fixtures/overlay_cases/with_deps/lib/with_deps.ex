defmodule WithDeps do
  @moduledoc false

  def ok, do: LocalDep.ok()
end
