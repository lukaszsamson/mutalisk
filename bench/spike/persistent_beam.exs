#!/usr/bin/env elixir
# bench/spike/persistent_beam.exs
#
# Phase C.2 spike for V16_PERFORMANCE: keep one BEAM running per
# sandbox, swap `:persistent_term` per mutant, re-run ExUnit
# programmatically. Measures the per-mutant cost in this mode for
# comparison with the cold-start `mix test` path.
#
# Run with:
#
#     elixir bench/spike/persistent_beam.exs
#
# This is a measurement tool, not production code. It loads a small
# self-contained target+test pair, then runs the test N times in the
# same BEAM, flipping a `:persistent_term` mutant id between runs.
# Each iteration emits its wall-clock to stdout.

ExUnit.start(autorun: false, formatters: [])

defmodule Spike.Target do
  # Imagine this is the user's lib module under mutation. The dispatch
  # picks one of two implementations from `:persistent_term` so we can
  # simulate a mutant flip without recompiling.
  def add(a, b) do
    case :persistent_term.get({__MODULE__, :variant}, :original) do
      :original -> a + b
      :mutant -> a - b
    end
  end
end

defmodule Spike.TargetTest do
  use ExUnit.Case, async: false

  test "add/2 returns the sum" do
    assert Spike.Target.add(2, 3) == 5
  end
end

defmodule Spike.Runner do
  @iterations 10

  def run do
    {cold_us, _} = :timer.tc(fn -> ExUnit.run() end)
    IO.puts("cold_run_us=#{cold_us}")

    # Subsequent runs share the loaded ExUnit + test modules. Flip the
    # variant via :persistent_term and re-run.
    samples =
      for i <- 1..@iterations do
        variant = if rem(i, 2) == 0, do: :mutant, else: :original
        :persistent_term.put({Spike.Target, :variant}, variant)

        {us, %{failures: failures}} = :timer.tc(fn -> ExUnit.run() end)
        IO.puts("iter=#{i} variant=#{variant} us=#{us} failures=#{failures}")
        us
      end

    avg = div(Enum.sum(samples), length(samples))
    IO.puts("hot_avg_us=#{avg} hot_avg_ms=#{div(avg, 1000)}")
    IO.puts("speedup_vs_cold=#{Float.round(cold_us / avg, 2)}x")
  end
end

Spike.Runner.run()
