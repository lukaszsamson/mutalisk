defmodule AppStartCallback do
  @moduledoc """
  M22 regression fixture.

  An OTP application whose `start/2` callback creates a named ETS
  table used by the rest of the app (Phoenix-style boot-time
  initialization). Mix worker handles this trivially because each
  child `mix test` invocation fully boots the app. Persistent worker
  requires the v1.7 F2 fix (start project apps at boot) for the
  table to exist by the time tests run.
  """
  use Application

  @impl Application
  def start(_type, _args) do
    table = :app_start_callback_kv

    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:public, :named_table, :set])
      _ -> :ok
    end

    Supervisor.start_link([], strategy: :one_for_one, name: AppStartCallback.Supervisor)
  end
end
