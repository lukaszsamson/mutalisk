defmodule Mut.PoolRunner do
  @moduledoc """
  Runs a list of mutants against a `Mut.Sandbox.Pool`, sequentially
  (`concurrency == 1`) or through `Mut.SandboxQueue`.

  Both paths return the pool as it stands after the last mutant, and both
  thread pool state forward: the sequential path uses the pool returned by
  `Mut.Sandbox.checkin/2` as the input to the next `checkout/1`, so sandbox
  rotation and poisoned-sandbox isolation behave the way the parallel path
  does. Discarding it (T34) would make `--concurrency 1` reuse a checked-out
  sandbox and diverge from the queue's bookkeeping.
  """

  alias Mut.Sandbox

  @type run_one :: (term, Sandbox.t() -> any)

  @spec run(Sandbox.Pool.t(), [term], pos_integer, run_one) :: Sandbox.Pool.t()
  def run(pool, mutants, 1, run_one) do
    mutants
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(pool, fn mutant, pool ->
      {:ok, sandbox, checked_out} = Sandbox.checkout(pool)
      run_one.(mutant, sandbox)
      # R6 (sequential mirror): a raise from `run_one` propagates before this
      # checkin, so a poisoned sandbox is never handed to the next mutant.
      Sandbox.checkin(sandbox, checked_out)
    end)
  end

  def run(pool, mutants, concurrency, run_one) do
    {:ok, queue} = Mut.SandboxQueue.start_link(pool)

    try do
      mutants
      |> Enum.sort_by(& &1.id)
      |> Task.async_stream(
        fn mutant ->
          {:ok, sandbox} = Mut.SandboxQueue.checkout(queue)

          # R6: check the sandbox back in ONLY on normal completion. The fallback
          # path resets the sandbox in its own `after`; if that reset fails twice
          # it raises (a poisoned sandbox would yield false verdicts for every
          # later mutant). On that raise we deliberately do NOT check it back in,
          # so no concurrent worker can pick up the contaminated sandbox before
          # the run tears down. It stays in the pool's `checked_out` set and is
          # still reclaimed by `destroy_pool`, so nothing leaks.
          run_one.(mutant, sandbox)
          Mut.SandboxQueue.checkin(queue, sandbox)
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      Mut.SandboxQueue.finalize(queue)
    rescue
      exception ->
        _ = Mut.SandboxQueue.finalize(queue)
        reraise exception, __STACKTRACE__
    end
  end
end
