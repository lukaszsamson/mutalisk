defmodule Mut.CliTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mut, as: MutTask
  alias Mut.Cli
  alias Mut.Cli.Options
  alias Mut.Mutator

  test "defaults come from config with built-in fallbacks" do
    assert {:ok, %Options{} = opts} = Cli.parse([], [])

    # M71: default is nil so discovery falls to the orchestrator's
    # umbrella-aware discover_files (single-app lib/, umbrella apps/*/lib/).
    assert opts.files == nil
    # M48: pure-default tier — dispatch+guard mutators + AtomLiteral, env
    # walker source on so AtomLiteral runs, but only AtomLiteral among the
    # env-walker literals.
    # M83: :pattern_shape joined the default enabled targets (Pin graduated).
    assert opts.enabled_targets == [:dispatch, :guard, :env_walker, :pattern_shape]
    assert "atom_literal" in opts.mutators

    refute Enum.any?(
             opts.mutators,
             &(&1 in ~w(string_literal float_literal nil_literal collection_empty))
           )

    assert opts.fail_at == 80.0
    assert opts.reporters == [:terminal, :stryker_json]
    assert opts.output_path == "stryker.report.json"
    assert opts.concurrency == min(System.schedulers_online(), 4)
    assert opts.max_mutants == nil
    assert opts.debug_plan == false
    # M65: default selection flipped to coverage_with_static_fallback.
    assert opts.selection == :coverage_with_static_fallback
    assert opts.test_paths == ["test"]
  end

  test "M48: default-on tier resolves to v1 dispatch+guard mutators + AtomLiteral" do
    {:ok, opts} = Cli.parse([], [])
    resolved = Cli.resolve_mutators(opts.mutators)

    assert resolved == Mutator.Defaults.default_on()
    assert Mutator.AtomLiteral in resolved
    refute Mutator.StringLiteral in resolved
  end

  test "M48: explicit --enable env_walker activates the full env-walker set (v1.15 compat)" do
    {:ok, opts} =
      Cli.parse(["--enable", "dispatch,guard,module_attribute,body_literal,env_walker"])

    # nil mutators => full set via resolve_mutators/1
    assert opts.mutators == nil
    resolved = Cli.resolve_mutators(opts.mutators)

    assert Enum.all?(
             [
               Mutator.StringLiteral,
               Mutator.FloatLiteral,
               Mutator.NilLiteral,
               Mutator.CollectionEmpty
             ],
             &(&1 in resolved)
           )
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

  test "--worker-type mix is a deprecated warn-once no-op" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, %Options{}} = Cli.parse(["--worker-type", "mix"])
      end)

    assert warning =~ "--worker-type is deprecated"
  end

  test "--worker-type persistent is rejected" do
    assert {:error, message} = Cli.parse(["--worker-type", "persistent"])
    assert message =~ "no longer supported"
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
