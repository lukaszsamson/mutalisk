defmodule Mut.SandboxQueue do
  @moduledoc """
  Tiny FIFO queue over a `Mut.Sandbox.Pool`.

  Used by the parallel worker prototype: each `Task.async_stream`
  worker checks out a sandbox before running the mutant and returns it
  on completion. The queue serializes pool mutations so the existing
  functional `Sandbox.checkout/checkin` API stays usable from
  concurrent callers.

  `checkout/2` blocks (with the given timeout) until a sandbox is
  available, so callers can keep the same imperative shape they had
  under the sequential reducer.
  """

  use GenServer

  alias Mut.Sandbox

  @spec start_link(Sandbox.Pool.t()) :: GenServer.on_start()
  def start_link(%Sandbox.Pool{} = pool), do: GenServer.start_link(__MODULE__, pool)

  @spec checkout(GenServer.server(), timeout()) :: {:ok, Sandbox.t()} | {:error, :timeout}
  def checkout(server, timeout \\ :infinity) do
    GenServer.call(server, :checkout, timeout)
  end

  @spec checkin(GenServer.server(), Sandbox.t()) :: :ok
  def checkin(server, %Sandbox{} = sandbox), do: GenServer.cast(server, {:checkin, sandbox})

  @spec finalize(GenServer.server()) :: Sandbox.Pool.t()
  def finalize(server) do
    pool = GenServer.call(server, :finalize, :infinity)
    GenServer.stop(server)
    pool
  end

  @impl GenServer
  def init(%Sandbox.Pool{} = pool), do: {:ok, %{pool: pool, waiters: :queue.new()}}

  @impl GenServer
  def handle_call(:checkout, from, state) do
    case Sandbox.checkout(state.pool) do
      {:ok, sandbox, pool} ->
        {:reply, {:ok, sandbox}, %{state | pool: pool}}

      {:error, :pool_empty} ->
        {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
    end
  end

  def handle_call(:finalize, _from, state), do: {:reply, state.pool, state}

  @impl GenServer
  def handle_cast({:checkin, sandbox}, state) do
    pool = Sandbox.checkin(sandbox, state.pool)

    case :queue.out(state.waiters) do
      {{:value, waiter}, waiters} ->
        case Sandbox.checkout(pool) do
          {:ok, sandbox, pool} ->
            GenServer.reply(waiter, {:ok, sandbox})
            {:noreply, %{state | pool: pool, waiters: waiters}}

          {:error, :pool_empty} ->
            {:noreply, %{state | pool: pool}}
        end

      {:empty, _waiters} ->
        {:noreply, %{state | pool: pool}}
    end
  end
end
