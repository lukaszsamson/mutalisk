defmodule Mix.Tasks.Mut.E2e do
  @moduledoc "End-to-end verification for mix mut against demo_app."

  use Mix.Task

  alias Mut.Reporter.StrykerJson

  @shortdoc "Runs mix mut end-to-end against demo_app"
  @fixture_root Path.expand("test/fixtures/demo_app")
  @golden_stable_ids Path.expand("test/golden/plan/demo_app_stable_ids.json")

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    default = run_fixture!("default", [])

    coverage =
      run_fixture!(
        "coverage",
        ["--selection", "coverage_with_static_fallback"]
      )

    attribute =
      run_fixture!(
        "attribute",
        ["--enable", "dispatch,guard,module_attribute"]
      )

    repeated =
      run_fixture!(
        "repeat",
        ["--enable", "dispatch,guard,module_attribute"]
      )

    incremental = run_incremental_scenario!()

    assert_default!(default)
    assert_coverage_non_regression!(default, coverage)
    assert_attribute!(attribute)
    assert_stable_ids!(attribute, repeated)
    assert_golden_ids!(attribute)
    assert_dsl_filtered!(attribute)
    assert_incremental!(incremental)
    assert_fixture_clean!()
    assert_baseline_failure_aborts!()

    IO.puts("mut.e2e default=#{summary_line(default)}")
    IO.puts("mut.e2e coverage=#{summary_line(coverage)}")
    IO.puts("mut.e2e attribute=#{summary_line(attribute)}")
    IO.puts("mut.e2e stable_ids=#{length(stable_ids(attribute.report))}")
    IO.puts("mut.e2e incremental=#{incremental_summary(incremental)}")
    IO.puts("mut.e2e stryker_json=:ok")
    IO.puts("mut.e2e fixture_status=clean")
  end

  # M106: cold run writes history; warm `--incremental` run on the UNCHANGED
  # tree must reuse every verdict (execute none) and reproduce the same answer.
  defp run_incremental_scenario! do
    File.rm_rf!(Path.join(@fixture_root, "_build/mut_history"))
    cold = run_fixture!("inc_cold", [])
    warm = run_fixture!("inc_warm", ["--incremental"])
    %{cold: cold, warm: warm}
  end

  defp assert_incremental!(%{cold: cold, warm: warm}) do
    if stable_ids(cold.report) != stable_ids(warm.report) do
      raise "incremental: stable ids drift between cold and warm runs"
    end

    if cold.counts.statuses != warm.counts.statuses do
      raise "incremental: status drift cold=#{inspect(cold.counts.statuses)} " <>
              "warm=#{inspect(warm.counts.statuses)}"
    end

    inc = warm.report["mutalisk"]["incremental"] || %{}
    reused = Map.get(inc, "reused", 0)
    executed = Map.get(inc, "executed", -1)
    total = Enum.sum(Map.values(warm.counts.statuses))

    unless reused == total and executed == 0 do
      raise "incremental: expected full reuse on unchanged tree, got " <>
              "reused=#{reused} executed=#{executed} total=#{total}"
    end

    assert_contains!(warm.output, "Incremental: #{reused} reused from history")
  end

  defp incremental_summary(%{warm: warm}) do
    inc = warm.report["mutalisk"]["incremental"] || %{}
    "reused=#{Map.get(inc, "reused", 0)} executed=#{Map.get(inc, "executed", 0)}"
  end

  defp run_fixture!(label, flags) do
    report_path = "stryker.#{label}.json"
    File.rm_rf!(Path.join(@fixture_root, report_path))

    started = System.monotonic_time(:millisecond)

    {output, exit_code} =
      System.cmd(
        "mix",
        ["mut", "--fail-at", "0", "--output-path", report_path] ++ flags,
        cd: @fixture_root,
        env: child_env(),
        stderr_to_stdout: true
      )

    wall_ms = System.monotonic_time(:millisecond) - started
    report_file = Path.join(@fixture_root, report_path)

    if exit_code != 0 do
      raise "mix mut #{label} failed with #{exit_code}\n#{output}"
    end

    unless File.exists?(report_file) do
      raise "mix mut #{label} did not write #{report_path}\n#{output}"
    end

    report = Mut.JSON.decode!(File.read!(report_file))
    :ok = StrykerJson.validate(report)

    File.rm!(report_file)

    %{
      label: label,
      output: output,
      report: report,
      wall_ms: wall_ms,
      counts: counts(report)
    }
  end

  defp assert_default!(run) do
    assert_contains!(run.output, "Mutation score:")
    assert_contains!(run.output, "Schema:")
    assert_contains!(run.output, "Fallback:")
    assert_contains!(run.output, "Schema build complete")

    assert_count!(run, :schema, 27)
    assert_count!(run, :fallback, 4)
    assert_status!(run, "CompileError", 0)
    assert_status!(run, "Timeout", 0)
    assert_status!(run, "RuntimeError", 0)
    assert_min_skipped!(run, 4)
    assert_score_range!(run, 67.0, 79.0)
    assert_metrics!(run.report, 4)
  end

  defp assert_attribute!(run) do
    assert_count!(run, :schema, 27)
    assert_count!(run, :fallback, 6)
    assert_score_range!(run, 69.0, 82.0)
    assert_metrics!(run.report, 6)
  end

  defp assert_coverage_non_regression!(static, coverage) do
    if stable_ids(static.report) != stable_ids(coverage.report) do
      raise "coverage stable ids differ from static"
    end

    for status <- ["Killed", "Survived"] do
      static_count = Map.get(static.counts.statuses, status, 0)
      coverage_count = Map.get(coverage.counts.statuses, status, 0)

      if static_count != coverage_count do
        raise "coverage #{status} count drift: static=#{static_count} coverage=#{coverage_count}"
      end

      # M22: byte-identity check on the actual stable_id partitioning,
      # not just count totals. Catches the silent-drift class where
      # coverage selection's narrowed test list would flip a specific
      # mutant from killed to survived while leaving the totals
      # unchanged.
      static_set = stable_ids_by_status(static.report, status)
      coverage_set = stable_ids_by_status(coverage.report, status)

      if static_set != coverage_set do
        missing = Enum.reject(static_set, &(&1 in coverage_set))
        extra = Enum.reject(coverage_set, &(&1 in static_set))

        raise "coverage #{status} stable_id set drift: " <>
                "missing=#{inspect(missing)} extra=#{inspect(extra)}"
      end
    end

    selection = coverage.report["mutalisk"]["selection"]
    phases = coverage.report["mutalisk"]["phase_timings"]

    assert_coverage_selection_mode!(selection["mode"])
    assert_coverage_phase_timings!(selection, phases)
  end

  # M89: accept either "coverage_with_static_fallback" (the requested mode) or
  # "downgraded_to_static" (M64's pathological-coverage fallback when wall_ms
  # exceeds the 10s floor on a small but jittery suite). The downgrade is the
  # M64 mechanism working as designed — coverage did run (it just took too
  # long, hence the wall_ms/phase_timing assertions still apply); the
  # stable-id set drift check in the caller is what protects correctness in
  # either mode. Strict equality would oscillate with sandbox jitter; this
  # passed for many releases by luck, the v1.24 flake surfaced it.
  defp assert_coverage_selection_mode!("coverage_with_static_fallback"), do: :ok

  defp assert_coverage_selection_mode!("downgraded_to_static") do
    IO.puts(
      "mut.e2e coverage: M64 fallback engaged (coverage downgraded_to_static; " <>
        "stable-id sets verified identical above)"
    )
  end

  defp assert_coverage_selection_mode!(other) do
    raise "coverage selection mode mismatch: #{inspect(other)}"
  end

  defp assert_coverage_phase_timings!(selection, phases) do
    unless selection["coverage_collection_wall_ms"] > 0 do
      raise "coverage collection wall time missing from selection metrics"
    end

    unless phases["coverage_collection_ms"] > 0 do
      raise "coverage_collection_ms missing from phase timings"
    end
  end

  defp assert_stable_ids!(left, right) do
    if stable_ids(left.report) != stable_ids(right.report) do
      raise "stable ids changed across repeated runs"
    end
  end

  defp assert_golden_ids!(run) do
    expected = @golden_stable_ids |> File.read!() |> Mut.JSON.decode!() |> Enum.sort()
    actual = stable_ids(run.report)

    if actual != expected do
      raise "stable ids differ from golden\nexpected=#{inspect(expected)}\nactual=#{inspect(actual)}"
    end
  end

  defp assert_dsl_filtered!(run) do
    if Map.has_key?(run.report["files"], "lib/dsl_user.ex") do
      raise "dsl_user.ex reported mutants, expected none"
    end
  end

  defp assert_fixture_clean! do
    {output, 0} = System.cmd("git", ["status", "--porcelain", "test/fixtures/demo_app"])
    allowed = [" M test/fixtures/demo_app/mix.exs", "?? test/fixtures/demo_app/mix.lock"]

    unexpected =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 in allowed))

    if unexpected != [] do
      raise "demo_app fixture dirty after e2e run:\n#{output}"
    end
  end

  defp assert_baseline_failure_aborts! do
    tmp_root = Path.expand(Path.join(["tmp", "mut_e2e_#{System.unique_integer([:positive])}"]))

    try do
      File.rm_rf!(tmp_root)
      File.mkdir_p!(Path.dirname(tmp_root))
      File.cp_r!(@fixture_root, tmp_root)
      File.rm_rf!(Path.join(tmp_root, "_build"))
      File.rm_rf!(Path.join(tmp_root, "deps"))

      test_file = Path.join(tmp_root, "test/arith_test.exs")

      File.write!(
        test_file,
        File.read!(test_file) <> "\ntest \"forced red baseline\", do: assert(false)\n"
      )

      {output, exit_code} =
        System.cmd("mix", ["mut", "--fail-at", "0"],
          cd: tmp_root,
          env: child_env(),
          stderr_to_stdout: true
        )

      if exit_code == 0 do
        raise "failing baseline unexpectedly exited 0\n#{output}"
      end

      if File.exists?(Path.join(tmp_root, "stryker.report.json")) do
        raise "failing baseline wrote stryker.report.json"
      end
    after
      File.rm_rf!(tmp_root)
    end
  end

  defp assert_metrics!(report, expected_fallback_count) do
    metrics = report["mutalisk"]["metrics"]

    required = [
      "fallback_count",
      "fallback_time_ms",
      "rollback_count",
      "invalid_mutants",
      "skipped",
      "fanout"
    ]

    missing = Enum.reject(required, &Map.has_key?(metrics, &1))

    if missing != [] do
      raise "mutalisk metrics missing keys: #{inspect(missing)}"
    end

    if metrics["fallback_count"] != expected_fallback_count do
      raise "fallback_count mismatch: #{inspect(metrics["fallback_count"])}"
    end
  end

  defp assert_count!(run, engine, expected) do
    actual = Map.get(run.counts.engines, Atom.to_string(engine), 0)

    if actual != expected do
      raise "#{run.label} expected #{expected} #{engine} mutants, got #{actual}"
    end
  end

  defp assert_status!(run, status, expected) do
    actual = Map.get(run.counts.statuses, status, 0)

    if actual != expected do
      raise "#{run.label} expected #{expected} #{status}, got #{actual}"
    end
  end

  defp assert_min_skipped!(run, minimum) do
    actual = run.report["mutalisk"]["metrics"]["skipped"] |> Map.values() |> Enum.sum()

    if actual < minimum do
      raise "#{run.label} expected at least #{minimum} skipped entries, got #{actual}"
    end
  end

  defp assert_score_range!(run, min, max) do
    score = score(run.counts.statuses)

    unless score >= min and score <= max do
      raise "#{run.label} score #{score} outside #{min}..#{max}"
    end
  end

  defp assert_contains!(output, value) do
    unless output =~ value do
      raise "expected output to contain #{inspect(value)}"
    end
  end

  defp counts(report) do
    mutants = mutants(report)
    engine = report["mutalisk"]["engine"]

    %{
      statuses: Enum.frequencies_by(mutants, & &1["status"]),
      engines: Enum.frequencies_by(mutants, &Map.fetch!(engine, &1["id"]))
    }
  end

  defp mutants(report) do
    report["files"]
    |> Map.values()
    |> Enum.flat_map(& &1["mutants"])
  end

  defp stable_ids(report), do: report |> mutants() |> Enum.map(& &1["id"]) |> Enum.sort()

  defp stable_ids_by_status(report, status) do
    report
    |> mutants()
    |> Enum.filter(&(&1["status"] == status))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp score(statuses) do
    killed = Map.get(statuses, "Killed", 0)
    survived = Map.get(statuses, "Survived", 0)
    Float.round(killed / (killed + survived) * 100, 1)
  end

  defp summary_line(run) do
    statuses = run.counts.statuses
    engines = run.counts.engines

    "score=#{score(statuses)} schema=#{Map.get(engines, "schema", 0)} fallback=#{Map.get(engines, "fallback", 0)} statuses=#{inspect(statuses)} wall_ms=#{run.wall_ms}"
  end

  defp child_env do
    [
      {"MIX_ENV", "test"},
      {"MUTALISK_PATH", Path.expand(".")}
    ]
  end
end
