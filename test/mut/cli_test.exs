defmodule Mut.CliTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mut, as: MutTask
  alias Mut.Cli
  alias Mut.Cli.Options

  test "defaults come from config with built-in fallbacks" do
    assert {:ok, %Options{} = opts} = Cli.parse([], [])

    assert opts.files == ["lib"]
    assert opts.mutators == nil
    assert opts.enabled_targets == [:dispatch, :guard]
    assert opts.fail_at == 80.0
    assert opts.reporters == [:terminal, :stryker_json]
    assert opts.output_path == "stryker.report.json"
    assert opts.concurrency == min(System.schedulers_online(), 4)
    assert opts.worker_type == :mix
    assert opts.max_mutants == nil
    assert opts.debug_plan == false
    assert opts.selection == :static
    assert opts.test_paths == ["test"]
  end

  test "CLI flags override config" do
    assert {:ok, opts} =
             Cli.parse(
               [
                 "--files",
                 "lib/foo.ex",
                 "--mutators",
                 "arithmetic,comparison",
                 "--enable",
                 "dispatch,guard,module_attribute",
                 "--fail-at",
                 "85.5",
                 "--reporters",
                 "terminal,stryker-json",
                 "--output-path",
                 "tmp/report.json",
                 "--concurrency",
                 "4",
                 "--max-mutants",
                 "10",
                 "--selection",
                 "coverage-with-static-fallback",
                 "--debug-plan"
               ],
               files: ["lib"],
               mutators: [:boolean],
               enabled_targets: [:dispatch],
               fail_at: 20.0,
               reporters: [:terminal],
               output_path: "configured.json",
               concurrency: 1,
               test_paths: ["spec"]
             )

    assert opts.files == ["lib/foo.ex"]
    assert opts.mutators == ["arithmetic", "comparison"]
    assert opts.enabled_targets == [:dispatch, :guard, :module_attribute]
    assert opts.fail_at == 85.5
    assert opts.reporters == [:terminal, :stryker_json]
    assert opts.output_path == "tmp/report.json"
    assert opts.concurrency == 4
    assert opts.max_mutants == 10
    assert opts.debug_plan == true
    assert opts.selection == :coverage_with_static_fallback
    assert opts.test_paths == ["spec"]
  end

  test "parses selection flag and rejects unknown modes" do
    assert {:ok, %{selection: :coverage}} = Cli.parse(["--selection", "coverage"])

    assert {:error, message} = Cli.parse(["--selection", "dynamic"])
    assert message =~ "unknown --selection mode :dynamic"
    assert message =~ "static, coverage, coverage_with_static_fallback"
  end

  test "coverage collection pathology uses 2x threshold with small-project floor" do
    refute MutTask.pathological_coverage_collection?(2_500, 400)
    refute MutTask.pathological_coverage_collection?(5_001, 400)
    assert MutTask.pathological_coverage_collection?(10_001, 400)
    assert MutTask.pathological_coverage_collection?(10_001, 5_000)
    refute MutTask.pathological_coverage_collection?(10_000, 5_000)
  end

  test "rejects invalid fail-at" do
    assert {:error, message} = Cli.parse(["--fail-at", "101"])
    assert message =~ "--fail-at must be between 0 and 100"
  end

  test "rejects unknown reporters" do
    assert {:error, message} = Cli.parse(["--reporters", "terminal,xml"])
    assert message =~ "unknown --reporters value :xml"
  end

  test "rejects unknown mutator names" do
    assert {:error, message} = Cli.parse(["--mutators", "arithmetik"])
    assert message =~ "unknown mutator"
    assert message =~ "arithmetic"
  end

  test "rejects duplicate flags" do
    assert {:error, message} = Cli.parse(["--files", "lib/a.ex", "--files", "lib/b.ex"])
    assert message =~ "conflicting duplicate flags"
  end

  test "rejects unknown options" do
    assert {:error, message} = Cli.parse(["--bogus"])
    assert message =~ "unknown option --bogus"
    assert message =~ "mix help mut"
  end

  test "rejects bad enable target and concurrency" do
    assert {:error, message} = Cli.parse(["--enable", "dispatch,pattern"])
    assert message =~ "unknown --enable target :pattern"

    assert {:error, message} = Cli.parse(["--concurrency", "0"])
    assert message =~ "--concurrency must be at least 1"
  end

  test "test_timeout_ms defaults to 10_000 and accepts overrides" do
    assert {:ok, %Options{test_timeout_ms: 10_000}} = Cli.parse([])
    assert {:ok, %Options{test_timeout_ms: 30_000}} = Cli.parse(["--test-timeout-ms", "30000"])
    assert {:ok, %Options{test_timeout_ms: 5_000}} = Cli.parse([], test_timeout_ms: 5_000)

    # CLI overrides config.
    assert {:ok, %Options{test_timeout_ms: 20_000}} =
             Cli.parse(["--test-timeout-ms", "20000"], test_timeout_ms: 5_000)
  end

  test "rejects out-of-range --test-timeout-ms" do
    assert {:error, message} = Cli.parse(["--test-timeout-ms", "100"])
    assert message =~ "--test-timeout-ms must be an integer between"

    assert {:error, message} = Cli.parse(["--test-timeout-ms", "700000"])
    assert message =~ "--test-timeout-ms must be an integer between"
  end

  test "resolves mutators and aliases" do
    assert Cli.resolve_mutators(["arithmetic"]) == [Mut.Mutator.Arithmetic]

    assert Cli.resolve_mutators(["comparison", "guard_comparison"]) == [
             Mut.Mutator.ComparisonBoundary,
             Mut.Mutator.ComparisonNegation,
             Mut.Mutator.GuardComparisonBoundary,
             Mut.Mutator.GuardComparisonNegation
           ]
  end
end
