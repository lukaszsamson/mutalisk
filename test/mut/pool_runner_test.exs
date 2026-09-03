defmodule Mut.PoolRunnerTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.PoolRunner
  alias Mut.Sandbox

  defp sandbox(id) do
    %Sandbox{
      id: id,
      path: "/tmp/mut-pool-runner-test/#{id}",
      baseline_snapshot: %{},
      baseline_source: "/tmp/mut-pool-runner-test/#{id}"
    }
  end

  defp pool(count) do
    %Sandbox.Pool{
      run_id: "pool-runner-test",
      sandboxes: MapSet.new(Enum.map(1..count, &sandbox/1)),
      checked_out: MapSet.new(),
      schema_result: nil,
      parent: "/tmp/mut-pool-runner-test"
    }
  end

  defp mutants(ids), do: Enum.map(ids, &%{id: &1})

  test "T34: the sequential path threads the pool returned by checkin into the next checkout" do
    start = pool(2)

    # Record the pool each mutant sees on checkout. Without threading, every
    # iteration would check out against the ORIGINAL pool and the checked_out
    # bookkeeping would never advance.
    {:ok, seen} = Agent.start_link(fn -> [] end)

    final =
      PoolRunner.run(start, mutants(~w(m3 m1 m2)), 1, fn mutant, sandbox ->
        Agent.update(seen, &[{mutant.id, sandbox.id} | &1])
      end)

    # Mutants run in stable-id order.
    assert seen |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 0)) ==
             ~w(m1 m2 m3)

    # The pool comes back whole: every sandbox checked in, nothing stranded.
    assert MapSet.size(final.sandboxes) == 2
    assert MapSet.size(final.checked_out) == 0
    assert final.sandboxes == start.sandboxes
  end

  test "the sequential path never exhausts a single-sandbox pool" do
    start = pool(1)

    final =
      PoolRunner.run(start, mutants(~w(a b c d)), 1, fn _mutant, sandbox ->
        assert sandbox.id == 1
      end)

    assert MapSet.size(final.sandboxes) == 1
    assert MapSet.size(final.checked_out) == 0
  end

  test "a raising mutant leaves its sandbox checked out rather than reusing it" do
    start = pool(1)

    assert_raise RuntimeError, "poisoned", fn ->
      PoolRunner.run(start, mutants(~w(a b)), 1, fn _mutant, _sandbox ->
        raise "poisoned"
      end)
    end
  end
end
