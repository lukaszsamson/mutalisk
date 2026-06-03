#!/usr/bin/env elixir
# M107: incremental-history validation harness (the trust gate).
#
# Proves the two properties the feature lives or dies on, against a temp copy of
# the demo_app fixture (so the real fixture is never touched), plus a wall-clock
# measurement:
#
#   (A) GROUND-TRUTH on an unchanged tree — a full (cold) run and an
#       `--incremental` (warm) run produce IDENTICAL per-mutant verdicts and an
#       identical score. Reuse must never change the answer.
#
#   (B) SOURCE-CHANGE INVALIDATION — edit ONE source file (a semantics-preserving
#       `a + b` -> `b + a` in Arith.score: baseline stays green), run warm
#       `--incremental`, and confirm reuse is FULLY invalidated (executed = all,
#       reused = 0) and the warm verdicts still equal a fresh FULL run on the
#       edited tree. The reuse key includes a coarse project fingerprint (review
#       P1a), so ANY source/test-support/config/dep change invalidates every
#       verdict — Mutalisk does not track per-mutant cross-file dependencies, so
#       per-function diff-scoping would be unsound. (Dependency-aware reuse that
#       restores diff-scoping is future work.)
#
# Run from the mutalisk root: elixir bench/m107_incremental_validation.exs
#
# Exit 0 = all properties hold. Non-zero = a divergence (the feature is unsafe).

defmodule M107 do
  @root Path.expand(".")
  @fixture Path.join(@root, "test/fixtures/demo_app")

  def main do
    a = ground_truth()
    b = source_change_invalidation()

    IO.puts("\n==== M107 SUMMARY ====")
    IO.puts("A ground-truth (unchanged tree):    #{verdict(a.ok)}")
    IO.puts("B source-change invalidation:        #{verdict(b.ok)}")

    IO.puts(
      "\nwall-clock: cold=#{a.cold_ms}ms  warm=#{a.warm_ms}ms  " <>
        "speedup=#{Float.round(a.cold_ms / max(a.warm_ms, 1), 2)}x  " <>
        "(warm executed #{a.executed}/#{a.total} mutants)"
    )

    IO.puts(
      "invalidation: a source edit invalidated reuse (executed #{b.executed}/#{b.total}, " <>
        "reused #{b.reused}); warm verdicts == full-run verdicts: #{b.matches_full}"
    )

    if a.ok and b.ok, do: System.halt(0), else: System.halt(1)
  end

  # ---- Property A: ground truth on unchanged tree ----
  defp ground_truth do
    dir = fresh_copy("ground_truth")
    clear_history(dir)

    {cold, cold_ms} = run(dir, [])
    {warm, warm_ms} = run(dir, ["--incremental"])

    same_verdicts = cold.verdicts == warm.verdicts
    same_score = cold.score == warm.score
    executed = warm.incremental["executed"] || 0
    none_executed = executed == 0

    ok = same_verdicts and same_score and none_executed

    IO.puts(
      "[A] cold score=#{cold.score} warm score=#{warm.score} " <>
        "verdicts_identical=#{same_verdicts} warm_executed=#{executed}"
    )

    %{
      ok: ok,
      cold_ms: cold_ms,
      warm_ms: warm_ms,
      executed: executed,
      total: map_size(warm.verdicts)
    }
  end

  # ---- Property B: a source change invalidates ALL reuse (sound, coarse) ----
  defp source_change_invalidation do
    dir = fresh_copy("source_change")
    clear_history(dir)

    # Cold run on the ORIGINAL tree -> history.
    {_cold, _} = run(dir, [])

    # Semantics-PRESERVING edit to Arith.score: `a + b` -> `b + a` (addition
    # commutes, so the baseline stays green — mutalisk refuses to run on a red
    # baseline — and the full-run verdicts are unchanged). This changes the
    # project fingerprint, which must invalidate EVERY reused verdict (review
    # P1a): a mutant elsewhere could call into arith.ex, so per-function reuse
    # would be unsound.
    arith = Path.join(dir, "lib/arith.ex")
    original = File.read!(arith)
    edited = String.replace(original, "(a + b) * (a - b)", "(b + a) * (a - b)")
    if edited == original, do: raise("source-change edit did not apply")
    File.write!(arith, edited)

    # Warm incremental on the EDITED tree (uses pre-edit history).
    {warm, _} = run(dir, ["--incremental"])

    # Ground truth: a fresh FULL run on the edited tree (no history reuse).
    clear_history(dir)
    {full, _} = run(dir, [])

    matches_full = warm.verdicts == full.verdicts
    total = map_size(warm.verdicts)
    # When nothing is reused the report omits the incremental block entirely
    # (M106), so derive from the absence: reused 0 -> everything executed.
    reused = warm.incremental["reused"] || 0
    executed = total - reused

    # A source change must invalidate ALL reuse (project fingerprint changed):
    # nothing reused, everything executed, and the answer still matches a full
    # run (no stale verdicts slipped through).
    fully_invalidated = reused == 0
    ok = matches_full and fully_invalidated

    IO.puts(
      "[B] warm executed=#{executed} reused=#{reused} matches_full=#{matches_full} " <>
        "fully_invalidated=#{fully_invalidated}"
    )

    %{
      ok: ok,
      executed: executed,
      reused: reused,
      total: map_size(warm.verdicts),
      matches_full: matches_full
    }
  end

  # ---- run mix mut against a fixture copy, parse the report ----
  defp run(dir, flags) do
    report = "stryker.m107.json"
    File.rm_rf!(Path.join(dir, report))
    started = System.monotonic_time(:millisecond)

    {output, code} =
      System.cmd("mix", ["mut", "--fail-at", "0", "--output-path", report] ++ flags,
        cd: dir,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @root}],
        stderr_to_stdout: true
      )

    elapsed = System.monotonic_time(:millisecond) - started
    path = Path.join(dir, report)

    unless code == 0 and File.exists?(path) do
      raise "mix mut #{inspect(flags)} failed (#{code})\n#{output}"
    end

    {parse(File.read!(path)), elapsed}
  end

  defp parse(json) do
    d = :json.decode(json)
    mutants = for {_file, info} <- d["files"], m <- info["mutants"], do: m
    verdicts = Map.new(mutants, &{&1["id"], &1["status"]})

    killed = Enum.count(mutants, &(&1["status"] in ["Killed", "Timeout"]))
    denom = Enum.count(mutants, &(&1["status"] in ["Killed", "Timeout", "Survived"]))
    score = if denom > 0, do: Float.round(killed / denom * 100, 1), else: 0.0

    %{
      verdicts: verdicts,
      score: score,
      incremental: d["mutalisk"]["incremental"] || %{},
      # mutants present this run keyed with their file, for diff-scope checks
      executed_ids:
        for({file, info} <- d["files"], m <- info["mutants"], do: %{id: m["id"], file: file})
    }
  end

  defp fresh_copy(name) do
    dir = Path.join([@root, "tmp", "m107", name])
    File.rm_rf!(dir)
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@fixture, dir)
    # Don't carry the fixture's build artifacts / any stray history.
    File.rm_rf!(Path.join(dir, "_build"))
    dir
  end

  defp clear_history(dir), do: File.rm_rf!(Path.join(dir, "_build/mut_history"))

  defp verdict(true), do: "PASS"
  defp verdict(false), do: "FAIL"
end

M107.main()
