defmodule Mut.LastKiller do
  @moduledoc """
  Tracks the last killing test file per module for one mutation run.

  Implementation: backed by `Agent` over a small `module() => Path.t()`
  map. Writes serialize through the Agent, reads are also serialized.
  This is intentional after the M17 concurrency audit:

  - The expected hot-path call rate is bounded by the parallel worker
    count (1-8) times the per-mutant kill rate (typically <50%). For
    Decimal at c=4 this is well under 1 record_kill/sec; for plug_crypto
    at c=4 around 0.3/sec. Agent's per-call overhead is dominated by
    message-passing latency (sub-millisecond on the reference machine,
    measured by the p99 stress test), so contention is not material.
  - `lookup/2` is on the test-selection hot path (called once per
    mutant). It returns a `Path.t() | nil`; semantically the value is
    a *hint* (the coverage selector uses it for prioritisation), not a
    correctness invariant. An ETS table with `read_concurrency: true`
    would be faster but introduces inconsistent-read windows that the
    Agent does not.
  - The map is bounded by the number of distinct user modules under
    test (tens to low hundreds). It does not grow unboundedly during a
    run.

  If a future workload pushes record_kill rates above ~1000/sec, swap
  the backing store for an ETS table with `:public, :write_concurrency`
  - the public API stays the same.
  """

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
