#!/usr/bin/env elixir
# M86 (redirected per M85 spike): cross-run delta over two Stryker JSON reports.
#
# Spike conclusion (`docs/spikes/M85_fallback_share.md`) was that schema-routing
# the dominant fallback constituents was non-viable by AST shape, so M86's
# scoped implementation would have delivered ≈ zero default-plan benefit.
# Per the plan's "real spike outcome, not a failure" framing, M86 is redirected
# to the incremental cross-run history *prelude* — a v1.25 candidate
# foundation that demonstrates the existing report carries enough state
# (per-mutant stable_id + status + duration + engine + mutator) to compute
# meaningful deltas across runs, without any engine change.
#
# Inputs: two paths to Stryker JSON reports produced by `mix mut`.
# Outputs (stdout): per-mutant status transition table, score delta, sets of
# new/removed stable IDs, per-mutator wall-clock delta. All deterministic.
#
# Usage:
#
#     elixir bench/cross_run.exs <before.json> <after.json>

defmodule CrossRun do
  def run([before_path, after_path]) do
    before_run = load(before_path)
    after_run = load(after_path)

    print_header(before_path, after_path)
    print_score_delta(before_run, after_run)
    print_status_transitions(before_run, after_run)
    print_id_sets(before_run, after_run)
    print_mutator_wall_delta(before_run, after_run)
  end

  def run(_other) do
    IO.puts(:stderr, "usage: elixir bench/cross_run.exs <before.json> <after.json>")
    System.halt(64)
  end

  defp load(path) do
    d = path |> File.read!() |> :json.decode()
    mutalisk = Map.get(d, "mutalisk", %{})
    engine = Map.get(mutalisk, "engine", %{})
    stable_int = Map.get(mutalisk, "stable_id_to_integer", %{})
    phase = Map.get(mutalisk, "phase_timings", %{})

    # Index mutants by stable_id (the cross-run-stable identity). The report
    # carries an `id` per mutant (a hash) and a stable_id_to_integer map; the
    # stable_id IS that hash key, so we use the mutant's `id` directly.
    mutants =
      for {file, info} <- Map.get(d, "files", %{}),
          mu <- Map.get(info, "mutants", []),
          into: %{} do
        mid = Map.get(mu, "id")

        {mid,
         %{
           id: mid,
           status: Map.get(mu, "status"),
           duration: Map.get(mu, "duration", 0),
           mutator: Map.get(mu, "mutatorName"),
           engine: Map.get(engine, mid, "?"),
           file: file,
           line: get_in(mu, ["location", "start", "line"])
         }}
      end

    %{mutants: mutants, phase: phase, stable_int: stable_int}
  end

  defp print_header(b, a) do
    IO.puts("# cross-run delta")
    IO.puts("before: #{b}")
    IO.puts("after:  #{a}")
    IO.puts("")
  end

  defp print_score_delta(b, a) do
    bk = count_status(b.mutants, "Killed")
    bs = count_status(b.mutants, "Survived")
    ak = count_status(a.mutants, "Killed")
    as = count_status(a.mutants, "Survived")
    score = fn k, s -> if k + s > 0, do: Float.round(k / (k + s) * 100, 1), else: 0.0 end

    IO.puts("## score")

    IO.puts(
      "  before: #{bk}/#{bk + bs} = #{score.(bk, bs)}%   after: #{ak}/#{ak + as} = #{score.(ak, as)}%   delta: #{ak - bk} killed, #{as - bs} survived"
    )

    bw = Map.get(b.phase, "total_ms", 0)
    aw = Map.get(a.phase, "total_ms", 0)
    IO.puts("  wall total_ms: before=#{bw} after=#{aw} delta=#{aw - bw}")
    IO.puts("")
  end

  defp print_status_transitions(b, a) do
    keys = MapSet.union(MapSet.new(Map.keys(b.mutants)), MapSet.new(Map.keys(a.mutants)))

    transitions =
      Enum.reduce(keys, %{}, fn id, acc ->
        bs = (b.mutants[id] || %{})[:status] || :missing
        as = (a.mutants[id] || %{})[:status] || :missing
        if bs == as, do: acc, else: Map.update(acc, {bs, as}, 1, &(&1 + 1))
      end)

    IO.puts("## status transitions (before -> after)")
    IO.puts("  (only mutants whose status differed)")

    transitions
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.each(fn {{bs, as}, n} -> IO.puts("    #{inspect(bs)} -> #{inspect(as)}: #{n}") end)

    IO.puts("")
  end

  defp print_id_sets(b, a) do
    b_ids = MapSet.new(Map.keys(b.mutants))
    a_ids = MapSet.new(Map.keys(a.mutants))
    new_ids = MapSet.difference(a_ids, b_ids)
    removed_ids = MapSet.difference(b_ids, a_ids)
    IO.puts("## stable id sets")

    IO.puts(
      "  unchanged: #{MapSet.intersection(a_ids, b_ids) |> MapSet.size()}   new: #{MapSet.size(new_ids)}   removed: #{MapSet.size(removed_ids)}"
    )

    IO.puts("")
  end

  defp print_mutator_wall_delta(b, a) do
    bw = group_wall(b.mutants)
    aw = group_wall(a.mutants)
    mutators = MapSet.union(MapSet.new(Map.keys(bw)), MapSet.new(Map.keys(aw)))
    IO.puts("## per-mutator wall delta (ms)")

    rows =
      for m <- mutators do
        before_ms = Map.get(bw, m, 0)
        after_ms = Map.get(aw, m, 0)
        {m, before_ms, after_ms, after_ms - before_ms}
      end

    rows
    |> Enum.sort_by(&(-abs(elem(&1, 3))))
    |> Enum.each(fn {m, b, a, d} ->
      sign = if d >= 0, do: "+", else: ""
      :io.format("  ~-24s before=~6w after=~6w delta=~s~w~n", [m, b, a, sign, d])
    end)
  end

  defp count_status(mutants, status),
    do: Enum.count(mutants, fn {_id, m} -> m.status == status end)

  defp group_wall(mutants) do
    Enum.reduce(mutants, %{}, fn {_id, m}, acc ->
      Map.update(acc, m.mutator, m.duration, &(&1 + m.duration))
    end)
  end
end

CrossRun.run(System.argv())
