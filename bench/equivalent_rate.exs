#!/usr/bin/env elixir
# M59 — per-mutator equivalent-rate estimate from a Stryker JSON report.
#
# Equivalence is undecidable; this is a documented HEURISTIC, an OVER-estimate:
#
#   equivalent-ish := a SURVIVED mutant that is COVERED by >=1 test
#                     (`coveredBy != []`).
#
# Rationale: if a test executes the mutated code yet the mutant survives, the
# change is unobservable to the suite — either a true equivalent mutant OR a
# weak assertion. Both are "the suite can't kill it"; we cannot tell them apart
# syntactically, so this conflates them (hence over-estimate). A survivor with
# NO coverage is "untested", NOT equivalent — excluded.
#
#   equivalent-rate := covered-survivors / (Killed + Survived)
#
# (Denominator = behavioural verdicts; CompileError/RuntimeError/Timeout and
# uncovered survivors are excluded.) Requires a coverage-selection run so
# `coveredBy` is real. Usage: elixir bench/equivalent_rate.exs <stryker.json> ...

defmodule EquivRate do
  def run(paths) do
    IO.puts("target               mutator                  killed surv  cov-surv  equiv-rate")
    IO.puts(String.duplicate("-", 78))
    Enum.each(paths, &report/1)
  end

  defp report(path) do
    target = path |> Path.basename() |> String.replace(~r/\..*$/, "")
    json = path |> File.read!() |> :json.decode()

    json
    |> Map.get("files", %{})
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, "mutants", []))
    |> Enum.group_by(&Map.get(&1, "mutatorName"))
    |> Enum.sort()
    |> Enum.each(fn {mutator, ms} -> print_row(target, mutator, ms) end)
  end

  defp print_row(target, mutator, ms) do
    killed = Enum.count(ms, &(&1["status"] == "Killed"))
    survived = Enum.count(ms, &(&1["status"] == "Survived"))
    cov_surv = Enum.count(ms, &(&1["status"] == "Survived" and &1["coveredBy"] not in [nil, []]))
    denom = killed + survived
    rate = if denom > 0, do: Float.round(cov_surv / denom * 100, 1), else: 0.0

    :io.format("~-20s ~-24s ~6w ~5w ~9w ~9.1f%~n", [
      target,
      mutator,
      killed,
      survived,
      cov_surv,
      rate
    ])
  end
end

case System.argv() do
  [] -> IO.puts(:stderr, "usage: elixir bench/equivalent_rate.exs <stryker.json> ...")
  paths -> EquivRate.run(paths)
end
