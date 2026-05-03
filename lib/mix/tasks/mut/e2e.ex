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

    attribute =
      run_fixture!("attribute", ["--enable", "dispatch,guard,module_attribute"])

    repeated = run_fixture!("repeat", ["--enable", "dispatch,guard,module_attribute"])

    assert_default!(default)
    assert_attribute!(attribute)
    assert_stable_ids!(attribute, repeated)
    assert_golden_ids!(attribute)
    assert_dsl_filtered!(attribute)
    assert_fixture_clean!()
    assert_baseline_failure_aborts!()

    IO.puts("mut.e2e default=#{summary_line(default)}")
    IO.puts("mut.e2e attribute=#{summary_line(attribute)}")
    IO.puts("mut.e2e stable_ids=#{length(stable_ids(attribute.report))}")
    IO.puts("mut.e2e stryker_json=:ok")
    IO.puts("mut.e2e fixture_status=clean")
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

    report = Jason.decode!(File.read!(report_file))
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

  defp assert_stable_ids!(left, right) do
    if stable_ids(left.report) != stable_ids(right.report) do
      raise "stable ids changed across repeated runs"
    end
  end

  defp assert_golden_ids!(run) do
    expected = @golden_stable_ids |> File.read!() |> Jason.decode!() |> Enum.sort()
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
