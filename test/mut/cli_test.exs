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
    # Default is nil so test-path resolution is umbrella-aware at runtime
    # (single app -> "test"; umbrella -> each app's "apps/<app>/test"). An
    # explicit config value is still honoured verbatim (see "spec" test below).
    assert opts.test_paths == nil
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
    assert {:error, message} = Cli.parse(["--concurrency", "1", "--concurrency", "2"])
    assert message =~ "conflicting duplicate flags"
  end

  test "does not mistake a repeated multi-word flag for a duplicate conflict (T46)" do
    # `--test-paths` (raw dash spelling) must match the underscore-spelled
    # `@repeatable_flags` entry ("test_paths") once normalised, or every
    # legitimately repeated `--test-paths` run is rejected as a duplicate-flag
    # conflict — exactly like `--files` already is.
    assert {:ok, opts} = Cli.parse(["--test-paths", "test/a", "--test-paths", "test/b"])
    assert opts.test_paths == ["test/a", "test/b"]
  end

  test "still rejects a genuinely duplicated non-repeatable flag after normalisation (T46)" do
    assert {:error, message} = Cli.parse(["--output-path", "a.json", "--output-path", "b.json"])
    assert message =~ "conflicting duplicate flags"
  end

  test "rejects contradictory boolean flag forms" do
    for argv <- [
          ["--incremental", "--no-incremental"],
          ["--debug-plan", "--no-debug-plan"],
          ["--keep-work-copy", "--no-keep-work-copy"]
        ] do
      assert {:error, message} = Cli.parse(argv)
      assert message =~ "conflicting duplicate flags"
    end
  end

  test "accepts repeated --files and collects every pattern (M122)" do
    assert {:ok, opts} = Cli.parse(["--files", "lib/a.ex", "--files", "lib/b.ex"])
    assert opts.files == ["lib/a.ex", "lib/b.ex"]
  end

  test "accepts multiple path tokens after one --files flag" do
    assert {:ok, opts} =
             Cli.parse([
               "--files",
               "lib/a.ex",
               "lib/b.ex",
               "lib/c.ex",
               "--reporters",
               "terminal"
             ])

    assert opts.files == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    assert opts.reporters == [:terminal]
  end

  test "accepts comma-separated --files patterns" do
    assert {:ok, opts} = Cli.parse(["--files", "lib/a.ex, lib/b.ex"])
    assert opts.files == ["lib/a.ex", "lib/b.ex"]
  end

  test "accepts --test-paths as a CLI switch mirroring --files (T37)" do
    assert {:ok, opts} = Cli.parse(["--test-paths", "test/a", "test/b"])
    assert opts.test_paths == ["test/a", "test/b"]

    assert {:ok, opts} = Cli.parse(["--test-paths", "test/a", "--test-paths", "test/b"])
    assert opts.test_paths == ["test/a", "test/b"]

    assert {:ok, opts} = Cli.parse(["--test-paths", "test/a, test/b"])
    assert opts.test_paths == ["test/a", "test/b"]

    # CLI overrides config, mirroring --files.
    assert {:ok, opts} = Cli.parse(["--test-paths", "test/cli"], test_paths: ["test/config"])
    assert opts.test_paths == ["test/cli"]
  end

  test "rejects absolute --test-paths, mirroring config :test_paths" do
    assert {:error, m} = Cli.parse(["--test-paths", Path.expand("test")])
    assert m =~ "--test-paths must contain project-relative paths"
  end

  test "still rejects unexpected arguments after non-files flags" do
    assert {:error, message} = Cli.parse(["--reporters", "terminal", "lib/a.ex"])
    assert message =~ "unexpected arguments lib/a.ex"
  end

  test "exclude preserves each regex's flags (R17)" do
    {:ok, opts} = Cli.parse([], exclude: [~r/ROUTER\.EX/i])

    # The case-insensitive flag must survive — joining `Regex.source/1` dropped
    # it, so a lowercase path would no longer match its uppercase pattern.
    assert is_list(opts.exclude)
    assert Enum.any?(opts.exclude, &Regex.match?(&1, "lib/app_web/router.ex"))
  end

  test "rejects unknown options" do
    assert {:error, message} = Cli.parse(["--bogus"])
    assert message =~ "unknown option --bogus"
    assert message =~ "mix help mut"
  end

  test "reports a missing value distinctly from an unknown option (T47)" do
    # `--output-path` with no following argument used to be reported as
    # "unknown option --output-path", which is misleading — the flag is known,
    # it's just missing its value.
    assert {:error, message} = Cli.parse(["--output-path"])
    assert message =~ "missing value for --output-path"
    refute message =~ "unknown option"

    # Immediately followed by another flag (no value in between) is the same
    # case.
    assert {:error, message} = Cli.parse(["--output-path", "--concurrency", "2"])
    assert message =~ "missing value for --output-path"

    # An unrecognized flag (even with an underscore, which OptionParser always
    # treats as invalid) stays "unknown option", not "missing value".
    assert {:error, message} = Cli.parse(["--bogus"])
    assert message =~ "unknown option --bogus"

    assert {:error, message} = Cli.parse(["--fail_at", "80"])
    assert message =~ "unknown option --fail_at"
    refute message =~ "missing value"
  end

  test "rejects bad enable target and concurrency" do
    assert {:error, message} = Cli.parse(["--enable", "dispatch,pattern"])
    assert message =~ "unknown --enable target :pattern"

    assert {:error, message} = Cli.parse(["--concurrency", "0"])
    assert message =~ "--concurrency must be at least 1"

    too_high = max(System.schedulers_online() * 4, 16) + 1
    assert {:error, message} = Cli.parse(["--concurrency", Integer.to_string(too_high)])
    assert message =~ "--concurrency must be between 1 and"
  end

  test "test_timeout_ms defaults to 10_000 and accepts overrides" do
    assert {:ok, %Options{test_timeout_ms: 10_000}} = Cli.parse([])
    assert {:ok, %Options{test_timeout_ms: 30_000}} = Cli.parse(["--test-timeout-ms", "30000"])
    assert {:ok, %Options{test_timeout_ms: 5_000}} = Cli.parse([], test_timeout_ms: 5_000)

    # CLI overrides config.
    assert {:ok, %Options{test_timeout_ms: 20_000}} =
             Cli.parse(["--test-timeout-ms", "20000"], test_timeout_ms: 5_000)
  end

  test "suite_timeout_ms defaults to nil and accepts overrides" do
    assert {:ok, %Options{suite_timeout_ms: nil}} = Cli.parse([])

    assert {:ok, %Options{suite_timeout_ms: 120_000}} =
             Cli.parse(["--suite-timeout-ms", "120000"])

    assert {:ok, %Options{suite_timeout_ms: 45_000}} = Cli.parse([], suite_timeout_ms: 45_000)

    # CLI overrides config.
    assert {:ok, %Options{suite_timeout_ms: 90_000}} =
             Cli.parse(["--suite-timeout-ms", "90000"], suite_timeout_ms: 45_000)
  end

  test "rejects out-of-range --suite-timeout-ms" do
    assert {:error, message} = Cli.parse(["--suite-timeout-ms", "100"])
    assert message =~ "--suite-timeout-ms must be an integer between"

    assert {:error, message} = Cli.parse(["--suite-timeout-ms", "3600001"])
    assert message =~ "--suite-timeout-ms must be an integer between"

    assert {:error, message} = Cli.parse([], suite_timeout_ms: "nope")
    assert message =~ "--suite-timeout-ms must be an integer between"
  end

  test "rejects out-of-range --test-timeout-ms" do
    assert {:error, message} = Cli.parse(["--test-timeout-ms", "100"])
    assert message =~ "--test-timeout-ms must be an integer between"

    assert {:error, message} = Cli.parse(["--test-timeout-ms", "700000"])
    assert message =~ "--test-timeout-ms must be an integer between"
  end

  describe "input validation (exploratory #11-28)" do
    test "rejects empty --reporters / --mutators / --enable" do
      assert {:error, m} = Cli.parse(["--reporters", ""])
      assert m =~ "reporters must not be empty"

      assert {:error, m} = Cli.parse(["--mutators", ""])
      assert m =~ "mutators must not be empty"

      assert {:error, m} = Cli.parse(["--enable", ""])
      assert m =~ "--enable targets must not be empty"
    end

    test "rejects empty config reporters / mutators / enabled_targets lists" do
      assert {:error, m} = Cli.parse([], reporters: [])
      assert m =~ "reporters must not be empty"

      assert {:error, m} = Cli.parse([], mutators: [])
      assert m =~ "mutators must not be empty"

      assert {:error, m} = Cli.parse([], enabled_targets: [])
      assert m =~ "--enable targets must not be empty"
    end

    test "rejects non-boolean config :incremental" do
      assert {:error, m} = Cli.parse([], incremental: "false")
      assert m =~ "incremental must be true or false"
    end

    test "rejects non-string / empty config :since" do
      assert {:error, m} = Cli.parse([], since: 123)
      assert m =~ "since must be a non-empty string"

      assert {:error, m} = Cli.parse([], since: [])
      assert m =~ "since must be a non-empty string"

      assert {:error, m} = Cli.parse([], since: " ")
      assert m =~ "since must be a non-empty string"
    end

    test "rejects non-string config :output_path and :history_path" do
      assert {:error, m} = Cli.parse([], output_path: 123)
      assert m =~ "output_path must be a non-empty string"

      assert {:error, m} = Cli.parse([], output_path: [])
      assert m =~ "output_path must be a non-empty string"

      assert {:error, m} = Cli.parse(["--output-path", " "])
      assert m =~ "output_path must be a non-empty string"

      assert {:error, m} = Cli.parse([], history_path: 123)
      assert m =~ "history_path must be a non-empty string"

      assert {:error, m} = Cli.parse([], history_path: [])
      assert m =~ "history_path must be a non-empty string"

      assert {:error, m} = Cli.parse([], history_path: " ")
      assert m =~ "history_path must be a non-empty string"
    end

    test "rejects unknown config keys" do
      assert {:error, m} = Cli.parse([], fail_att: 0)
      assert m =~ "unknown config key :fail_att"

      assert {:error, m} = Cli.parse([], reporter: [:html])
      assert m =~ "unknown config key :reporter"
    end

    test "rejects non-string config :files / :test_paths (no silent coercion)" do
      assert {:error, m} = Cli.parse([], files: 123)
      assert m =~ "config :files must be a string or list of strings"

      assert {:error, m} = Cli.parse([], files: [123])
      assert m =~ "config :files must be a string or list of strings"

      assert {:error, m} = Cli.parse([], test_paths: [123])
      assert m =~ "config :test_paths must be a string or list of strings"
    end

    test "rejects non-string/atom :mutators entries without crashing" do
      assert {:error, m} = Cli.parse([], mutators: [123])
      assert m =~ "config :mutators must contain only strings or atoms"

      assert {:error, m} = Cli.parse([], mutators: 123)
      assert m =~ "config :mutators must be a string, atom, or list"

      # atoms are still accepted
      assert {:ok, _} = Cli.parse([], mutators: [:arithmetic])
    end

    test "rejects non-string/atom :selection without crashing" do
      assert {:error, m} = Cli.parse([], selection: 123)
      assert m =~ "selection must be one of"

      # atom + string still accepted
      assert {:ok, %{selection: :coverage}} = Cli.parse([], selection: :coverage)
      assert {:ok, %{selection: :static}} = Cli.parse(["--selection", "static"])

      assert {:ok, %{selection: :coverage_with_static_fallback}} =
               Cli.parse([], selection: :"coverage-with-static-fallback")
    end

    test "still accepts valid string/list values" do
      assert {:ok, %Options{files: ["lib/a.ex"], test_paths: ["test"]}} =
               Cli.parse([], files: "lib/a.ex", test_paths: ["test"])

      assert {:ok, %Options{incremental: true, since: "HEAD~1", history_path: "h.json"}} =
               Cli.parse([], incremental: true, since: "HEAD~1", history_path: "h.json")
    end
  end

  describe "input validation (exploratory #51-70)" do
    test "rejects empty / blank / empty-list --files (no whole-project or no-op run)" do
      # #54: "" would expand to the whole project
      assert {:error, m} = Cli.parse(["--files", ""])
      assert m =~ "--files contains a blank path"

      # #53: whitespace-only
      assert {:error, m} = Cli.parse(["--files", " "])
      assert m =~ "--files contains a blank path"

      # #55: config files: []
      assert {:error, m} = Cli.parse([], files: [])
      assert m =~ "config :files must not be empty"
    end

    test "rejects empty config :test_paths (#56)" do
      assert {:error, m} = Cli.parse([], test_paths: [])
      assert m =~ "config :test_paths must not be empty"
    end

    test "rejects absolute config :test_paths" do
      assert {:error, m} = Cli.parse([], test_paths: [Path.expand("test")])
      assert m =~ "config :test_paths must contain project-relative paths"
    end

    test "names the option and blames the extra comma for a blank --files segment (T51)" do
      assert {:error, m} = Cli.parse(["--files", "a.ex,,b.ex"])
      assert m =~ "--files has an empty segment in"
      assert m =~ "remove the extra comma"

      assert {:error, m} = Cli.parse(["--test-paths", "test/a,,test/b"])
      assert m =~ "--test-paths has an empty segment in"
      assert m =~ "remove the extra comma"
    end

    test "rejects trailing-comma empty segments in reporters/mutators/enable (#65-67)" do
      assert {:error, m} = Cli.parse(["--reporters", "terminal,"])
      assert m =~ "empty segment"

      assert {:error, m} = Cli.parse(["--mutators", "arithmetic,"])
      assert m =~ "empty segment"

      assert {:error, m} = Cli.parse(["--enable", "dispatch,"])
      assert m =~ "empty segment"
    end

    test "unknown reporter error uses documented hyphen spelling (#68)" do
      assert {:error, m} = Cli.parse(["--reporters", "nope"])
      assert m =~ "stryker-json"
      assert m =~ "github-actions"
      refute m =~ "stryker_json"
    end

    test "config reporters/enabled_targets non-string entries get a config type error (#69,#70)" do
      assert {:error, m} = Cli.parse([], reporters: [123])
      assert m =~ "config :reporters must contain only strings or atoms"

      assert {:error, m} = Cli.parse([], enabled_targets: [123])
      assert m =~ "config :enabled_targets must contain only strings or atoms"
    end

    test "valid comma lists and atom config still parse" do
      assert {:ok, %Options{reporters: [:terminal, :html]}} =
               Cli.parse(["--reporters", "terminal,html"])

      assert {:ok, %Options{reporters: [:terminal]}} = Cli.parse([], reporters: [:terminal])

      assert {:ok, %Options{files: ["lib/a.ex", "lib/b.ex"]}} =
               Cli.parse([], files: ["lib/a.ex", "lib/b.ex"])
    end

    test "deduplicates repeated reporters" do
      assert {:ok, %Options{reporters: [:html]}} = Cli.parse(["--reporters", "html,html"])

      assert {:ok, %Options{reporters: [:terminal]}} =
               Cli.parse([], reporters: [:terminal, :terminal])
    end
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

  test "accepts CamelCase mutator names as shown in reports" do
    # The terminal/HTML reports label mutators by their CamelCase module name;
    # a name copied from a report must validate (parse) and resolve.
    assert {:ok, opts} = Cli.parse(["--mutators", "Arithmetic,ComparisonBoundary"])

    assert Cli.resolve_mutators(opts.mutators) == [
             Mut.Mutator.Arithmetic,
             Mut.Mutator.ComparisonBoundary
           ]

    assert Cli.resolve_mutators(["GuardComparisonBoundary"]) == [
             Mut.Mutator.GuardComparisonBoundary
           ]
  end
end
