defmodule Mut.LastKiller do
  @moduledoc "Tracks the last killing test file per module for one mutation run."

  use Agent

  @spec start_link(opts :: keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, opts)

  @spec record_kill(GenServer.server(), module(), Path.t()) :: :ok
  def record_kill(server, module, test_file)
      when is_atom(module) and is_binary(test_file) do
    Agent.update(server, &Map.put(&1, module, test_file))
  end

  @spec lookup(GenServer.server(), module()) :: Path.t() | nil
  def lookup(server, module) when is_atom(module), do: Agent.get(server, &Map.get(&1, module))

  @spec snapshot(GenServer.server()) :: %{module() => Path.t()}
  def snapshot(server), do: Agent.get(server, & &1)
end
