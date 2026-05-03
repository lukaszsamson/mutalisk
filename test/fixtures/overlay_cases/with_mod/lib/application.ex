defmodule WithMod.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
