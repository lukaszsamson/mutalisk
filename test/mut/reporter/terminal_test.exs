defmodule Mut.Reporter.TerminalTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Reporter.Terminal
  alias Mut.Worker.Result

  setup do
    ansi_enabled = Application.get_env(:elixir, :ansi_enabled)
    no_color = System.get_env("NO_COLOR")

    Application.put_env(:elixir, :ansi_enabled, true)
    System.delete_env("NO_COLOR")

    on_exit(fn ->
      restore_env(:ansi_enabled, ansi_enabled)
      restore_system_env("NO_COLOR", no_color)
    end)
  end

  test "stream_event writes ANSI colored progress line" do
    mutant = mutant(:schema, :killed, "a", 1)
    result = %Result{status: :killed, duration_ms: 12}
    snapshot = snapshot([entry(mutant, result)], planned_total: 33)

    output =
      ExUnit.CaptureIO.capture_io(fn -> Terminal.stream_event(snapshot, mutant, result) end)

    assert output =~ "[1/33]"
    assert output =~ IO.ANSI.green()
    assert output =~ "killed"
    assert output =~ "lib/arith.ex:5"
    assert output =~ "Arithmetic"
    assert output =~ "replace + with -"
  end

  test "stream_event honors NO_COLOR" do
    System.put_env("NO_COLOR", "1")

    mutant = mutant(:schema, :survived, "a", 1)
    result = %Result{status: :survived, duration_ms: 12}
    snapshot = snapshot([entry(mutant, result)], total: 1)

    output =
      ExUnit.CaptureIO.capture_io(fn -> Terminal.stream_event(snapshot, mutant, result) end)

    refute output =~ "\e["
    assert output == "[1/1] survived  lib/arith.ex:5  Arithmetic  replace + with -\n"
  end

  test "render_summary is byte stable" do
    schema_killed = mutant(:schema, :killed, "schema-killed", 1)
    schema_survived = mutant(:schema, :survived, "schema-survived", 2)
    fallback_killed = mutant(:fallback, :killed, "fallback-killed", 3)
    fallback_survived = mutant(:fallback, :survived, "fallback-survived", 4)

    summary =
      [
        entry(schema_killed, %Result{status: :killed, duration_ms: 1000}),
        entry(schema_survived, %Result{status: :survived, duration_ms: 2000}),
        entry(fallback_killed, %Result{status: :killed, duration_ms: 3000}),
        entry(fallback_survived, %Result{status: :survived, duration_ms: 4000})
      ]
      |> snapshot(
        by_status: %{killed: 2, survived: 2, skipped: 1, invalid: 1, error: 1, timeout: 1},
        by_engine_status: %{
          {:schema, :killed} => 1,
          {:schema, :survived} => 1,
          {:fallback, :killed} => 1,
          {:fallback, :survived} => 1
        },
        wall_clock_ms: %{schema: 3000, fallback: 7000, total: 10_000},
        fallback_count_pct: 50.0,
        skipped_by_reason: %{unsupported_dispatch: 1},
        invalid_by_mutator: %{Mut.Reporter.TerminalTest => 1},
        score: 50.0
      )
      |> Terminal.render_summary()
      |> IO.iodata_to_binary()

    assert summary == """
           Mutation score: 2/4 = 50.0%

           Surviving mutants:
             lib/arith.ex:5 Arithmetic               replace + with -
             lib/arith.ex:5 Arithmetic               replace + with -

           Schema:    1/2 killed (50.0%)   wall: 3.0s
           Fallback:  1/2 killed (50.0%)   wall: 7.0s
             arithmetic_op:                1/2 killed
           Skipped:   1 (unsupported_dispatch: 1)
           Invalid:   1 (Elixir.Mut.Reporter.TerminalTest: 1)
           Errors:    1
           Timeouts:  1

           Run time: 10.0s
           Fallback wall-clock: 70.0% of total
           Fallback mutants: 50.0% of executed
           """
  end

  defp snapshot(entries, opts) do
    %Snapshot{
      total: Keyword.get(opts, :total, length(entries)),
      planned_total: Keyword.get(opts, :planned_total),
      score: Keyword.get(opts, :score, 100.0),
      by_status: Keyword.get(opts, :by_status, %{}),
      by_engine_status: Keyword.get(opts, :by_engine_status, %{}),
      fallback_count_pct: Keyword.get(opts, :fallback_count_pct, 0.0),
      wall_clock_ms: Keyword.get(opts, :wall_clock_ms, %{schema: 0, fallback: 0, total: 0}),
      rollback_per_file: %{},
      invalid_by_mutator: Keyword.get(opts, :invalid_by_mutator, %{}),
      skipped_by_reason: Keyword.get(opts, :skipped_by_reason, %{}),
      test_selection_fanout: %{},
      ledger: entries
    }
  end

  defp entry(mutant, result) do
    %{
      id: mutant.id,
      stable_id: mutant.stable_id,
      engine: mutant.engine,
      status: result.status,
      mutation_kind: mutant.mutation_kind,
      mutant: mutant,
      result: result
    }
  end

  defp mutant(engine, status, stable_id, id) do
    %Mutant{
      id: id,
      stable_id: stable_id,
      engine: engine,
      mutator: __MODULE__,
      mutator_name: "Arithmetic",
      mutation_kind: :arithmetic_op,
      original_dispatch: "+/2",
      file: "lib/arith.ex",
      line: 5,
      column: 8,
      span: {5, 8, 5, 13},
      original_ast: quote(do: a + b),
      mutated_ast: quote(do: a - b),
      description: "replace + with -",
      status: status
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:elixir, key)
  defp restore_env(key, value), do: Application.put_env(:elixir, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
