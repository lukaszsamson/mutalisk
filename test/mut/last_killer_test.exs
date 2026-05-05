defmodule Mut.LastKillerTest do
  use ExUnit.Case, async: true

  test "records and looks up the last killing test by module" do
    {:ok, killer} = Mut.LastKiller.start_link([])

    assert Mut.LastKiller.lookup(killer, Sample.Module) == nil
    assert :ok = Mut.LastKiller.record_kill(killer, Sample.Module, "test/sample_test.exs")
    assert Mut.LastKiller.lookup(killer, Sample.Module) == "test/sample_test.exs"
    assert Mut.LastKiller.snapshot(killer) == %{Sample.Module => "test/sample_test.exs"}
  end

  test "state is isolated per started process" do
    {:ok, first} = Mut.LastKiller.start_link([])
    {:ok, second} = Mut.LastKiller.start_link([])

    Mut.LastKiller.record_kill(first, Sample.Module, "test/first_test.exs")

    assert Mut.LastKiller.lookup(first, Sample.Module) == "test/first_test.exs"
    assert Mut.LastKiller.lookup(second, Sample.Module) == nil
  end

  test "8 concurrent producers + readers do not deadlock or corrupt state" do
    {:ok, killer} = Mut.LastKiller.start_link([])

    modules = for i <- 1..8, do: Module.concat(["LK", "Stress", "M#{i}"])
    iterations = 200

    producers =
      for {module, idx} <- Enum.with_index(modules, 1) do
        Task.async(fn ->
          for n <- 1..iterations do
            Mut.LastKiller.record_kill(killer, module, "test/lk_#{idx}_#{n}.exs")
          end
        end)
      end

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          for _ <- 1..iterations do
            Enum.each(modules, &Mut.LastKiller.lookup(killer, &1))
          end
        end)
      end

    Task.await_many(producers ++ readers, 30_000)

    snapshot = Mut.LastKiller.snapshot(killer)

    for {module, idx} <- Enum.with_index(modules, 1) do
      assert Map.has_key?(snapshot, module)
      assert Regex.match?(~r"^test/lk_#{idx}_\d+\.exs$", Map.fetch!(snapshot, module))
    end
  end

  test "record_kill p99 under sustained load stays sub-millisecond" do
    {:ok, killer} = Mut.LastKiller.start_link([])
    samples = 5_000
    module = LK.Perf.Module

    durations =
      for n <- 1..samples do
        {us, :ok} =
          :timer.tc(fn ->
            Mut.LastKiller.record_kill(killer, module, "test/perf_#{n}.exs")
          end)

        us
      end

    sorted = Enum.sort(durations)
    p99 = Enum.at(sorted, div(samples * 99, 100))

    # Agent.update on a tiny map should be well under a millisecond per call.
    # If this ever regresses we'd want to consider an ETS-backed implementation.
    assert p99 < 1_000, "p99 record_kill latency #{p99}us exceeds 1ms"
  end
end
