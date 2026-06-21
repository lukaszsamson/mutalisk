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
  def handle_call(:checkout, {pid, _tag} = from, state) do
    case Sandbox.checkout(state.pool) do
      {:ok, sandbox, pool} ->
        {:reply, {:ok, sandbox}, %{state | pool: pool}}

      {:error, :pool_empty} ->
        # Monitor the waiter so a checkin never hands a sandbox to a dead
        # caller (which would silently leak it from the pool and, after a few
        # such losses, deadlock the orchestrator at `checkout`).
        ref = Process.monitor(pid)
        {:noreply, %{state | waiters: :queue.in({from, ref, pid}, state.waiters)}}
    end
  end

  def handle_call(:finalize, _from, state), do: {:reply, state.pool, state}

  @impl GenServer
  def handle_cast({:checkin, sandbox}, state) do
    {pool, waiters} = dispatch(Sandbox.checkin(sandbox, state.pool), state.waiters)
    {:noreply, %{state | pool: pool, waiters: waiters}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiters = :queue.filter(fn {_from, r, _pid} -> r != ref end, state.waiters)
    {:noreply, %{state | waiters: waiters}}
  end

  # Hand the just-returned sandbox to the first STILL-LIVING waiter, skipping
  # any that died while queued (their monitor may not have fired yet).
  defp dispatch(pool, waiters) do
    case :queue.out(waiters) do
      {{:value, {from, ref, pid}}, rest} ->
        Process.demonitor(ref, [:flush])
        hand_off(pool, from, pid, rest)

      {:empty, _waiters} ->
        {pool, waiters}
    end
  end

  defp hand_off(pool, from, pid, rest) do
    # Skip a waiter that died while queued; try the next.
    if Process.alive?(pid), do: give(pool, from, pid, rest), else: dispatch(pool, rest)
  end

  defp give(pool, from, pid, rest) do
    case Sandbox.checkout(pool) do
      {:ok, sandbox, pool} ->
        GenServer.reply(from, {:ok, sandbox})
        {pool, rest}

      {:error, :pool_empty} ->
        # No sandbox free (more living waiters than returned sandboxes);
        # re-monitor and keep this waiter at the front of the queue.
        {pool, :queue.in_r({from, Process.monitor(pid), pid}, rest)}
    end
  end
end
