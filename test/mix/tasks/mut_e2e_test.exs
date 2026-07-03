defmodule Mix.Tasks.MutE2ETest do
  # True end-to-end guard for the #40/#49 artifact-root relocation: drives
  # `mix mut` as a CHILD process against the real `demo_app` fixture and asserts
  # on its observable output + on-disk side effects. The in-process integration
  # suite did NOT catch the symlink-canonicalization regression (uncanonicalized
  # OS-temp root → `Path.relative_to` prefix-stripping in `Mut.Trace` fails →
  # every mutant silently skipped as `missing_oracle_site` → 0/0 with exit 0).
  # This test reproduces that class of failure from the outside.
  #
  # `async: false`: the assertions inspect the checkout's `tmp/` for artifacts
  # the child must NOT write there, so no other test file may run concurrently.
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :e2e

  # test/mix/tasks/mut_e2e_test.exs -> checkout root
  @checkout Path.expand("../../..", __DIR__)
  @target Path.join(@checkout, "test/fixtures/demo_app")

  # Keep it fast but leave headroom for a cold `mix mut` (first run recompiles
  # the mutalisk dep into the fixture's _build).
  @tag timeout: 180_000
  test "mix mut runs end-to-end against a real target with artifacts under the OS-temp root" do
    footprint_before = checkout_tmp_footprint()

    # Fast, portable, minimal-write config:
    #   --selection static   → skip coverage collection
    #   --max-mutants 3      → tiny execution set
    #   --fail-at 0          → never exit 1 on the threshold (score-agnostic)
    #   --reporters terminal → no stryker.report.json / .html written to the fixture
    #   --keep-work-copy     → print the retained artifact paths (assertion #4)
    {output, exit_status} =
      System.cmd(
        "mix",
        ~w(mut --selection static --max-mutants 3 --fail-at 0 --reporters terminal --keep-work-copy),
        cd: @target,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
        stderr_to_stdout: true
      )

    retained = retained_work_copies(output)

    # Register cleanup BEFORE the assertions so a failing assertion still tears
    # down the per-project artifact root under the OS temp dir.
    on_exit(fn ->
      for root <- artifact_roots_to_clean(retained), do: File.rm_rf!(root)
    end)

    # ---- 1. exit 0 with a NON-ZERO executed-mutant denominator ----------------
    # The symlink regression produced "Mutation score: 0/0" with exit success.
    assert exit_status == 0, "mix mut exited #{exit_status}\n\n#{output}"

    {detected, denominator} = parse_score(output)

    assert denominator > 0,
           "expected a non-zero mutant denominator (0/0 is the #40/#49 regression signature)\n\n#{output}"

    # ---- 2. at least one mutant actually detected (schema engine ran tests) ---
    assert detected > 0, "expected at least one detected mutant\n\n#{output}"

    # ---- 3. nothing written under the checkout's tmp/ by the run --------------
    footprint_after = checkout_tmp_footprint()

    new_paths = MapSet.difference(footprint_after, footprint_before)

    assert MapSet.size(new_paths) == 0,
           "mix mut wrote runtime artifacts under the checkout tmp/ (should be OS-temp only): " <>
             inspect(MapSet.to_list(new_paths))

    # ---- 4. --keep-work-copy paths live under the canonical OS-temp root ------
    canonical_tmp = canonical(System.tmp_dir!())

    assert retained != [],
           "expected --keep-work-copy retention paths in the output\n\n#{output}"

    for path <- retained do
      assert String.starts_with?(path, canonical_tmp),
             "retained path #{path} is not under the canonical OS temp root #{canonical_tmp}"

      assert String.contains?(path, "/mutalisk/"),
             "retained path #{path} is not under a per-project /mutalisk/ artifact root"

      refute String.starts_with?(path, @checkout),
             "retained path #{path} is under the mutalisk checkout (must be OS-temp)"

      assert File.exists?(path), "retained path #{path} does not exist on disk"
    end
  end

  @tag timeout: 180_000
  test "mix mut preserves conventional _build/test fixture paths" do
    root = tmp_project!("build_path_app")
    on_exit(fn -> File.rm_rf!(root) end)

    write_build_path_probe!(root)

    assert {test_output, 0} =
             System.cmd("mix", ["test"],
               cd: root,
               env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
               stderr_to_stdout: true
             )

    assert test_output =~ ~r/(0 failures|Result: 2 passed)/

    {output, exit_status} =
      System.cmd(
        "mix",
        ~w(mut --selection static --files lib/build_path_app.ex --max-mutants 1 --fail-at 0 --reporters terminal --concurrency 1),
        cd: root,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    refute output =~ "baseline tests failed", output
    assert output =~ "Mutation score:"

    {_detected, denominator} = parse_score(output)
    assert denominator > 0, output
  end

  @tag timeout: 180_000
  test "mix mut runs selected tests in custom apps_path umbrella children" do
    root = tmp_project!("custom_apps_path_umbrella")
    on_exit(fn -> File.rm_rf!(root) end)

    write_custom_apps_path_umbrella!(root)

    assert {test_output, 0} =
             System.cmd("mix", ["test"],
               cd: root,
               env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
               stderr_to_stdout: true
             )

    assert test_output =~ ~r/(0 failures|Result: 1 passed)/

    {output, exit_status} =
      System.cmd(
        "mix",
        ~w(mut --selection static --files packages/core/lib/core.ex --mutators boolean --max-mutants 1 --fail-at 0 --reporters terminal --concurrency 1),
        cd: root,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    refute output =~ "Paths given to \"mix test\" did not match", output
    refute output =~ "[1/1] error", output

    {detected, denominator} = parse_score(output)
    assert denominator > 0, output
    assert detected > 0, output
  end

  @tag timeout: 180_000
  test "configured relative history_path starts cold without an unusable warning" do
    root = tmp_project!("configured_history_path")
    on_exit(fn -> File.rm_rf!(root) end)

    write_configured_history_probe!(root)

    {output, exit_status} =
      System.cmd(
        "mix",
        ~w(mut --incremental),
        cd: root,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    refute output =~ "configured history_path", output
    refute output =~ "unusable (absent)", output
    assert File.exists?(Path.join(root, "tmp/custom-history.json"))
  end

  @tag timeout: 180_000
  test "malformed configured history_path warns once before being replaced" do
    root = tmp_project!("malformed_history_path")
    on_exit(fn -> File.rm_rf!(root) end)

    write_configured_history_probe!(root)
    history_path = Path.join(root, "tmp/custom-history.json")
    File.mkdir_p!(Path.dirname(history_path))
    File.write!(history_path, "{bad json")

    {output, exit_status} =
      System.cmd(
        "mix",
        ~w(mut --incremental),
        cd: root,
        env: [{"MIX_ENV", "test"}, {"MUTALISK_PATH", @checkout}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    assert output =~ "configured history_path"
    assert output =~ "unusable (malformed)"
    assert length(Regex.scan(~r/configured history_path/, output)) == 1
    assert {:ok, _decoded} = Mut.JSON.decode(File.read!(history_path))
  end

  # Parse "Mutation score: X/N" (both "X/N = P%" and the "0/0 (no scorable
  # mutants)" no-op line match, so N==0 is observable and asserted against).
  defp parse_score(output) do
    case Regex.run(~r/Mutation score: (\d+)\/(\d+)/, output) do
      [_, detected, denominator] ->
        {String.to_integer(detected), String.to_integer(denominator)}

      _ ->
        flunk("could not find a \"Mutation score: X/N\" line in output\n\n#{output}")
    end
  end

  # The two `--keep-work-copy` retention lines printed to stderr:
  #   [mutalisk] --keep-work-copy: retaining schema-build work copy <path>
  #   [mutalisk] --keep-work-copy: retaining oracle/baseline work copy <path>
  defp retained_work_copies(output) do
    ~r/--keep-work-copy: retaining .* work copy (\S+)/
    |> Regex.scan(output)
    |> Enum.map(fn [_, path] -> path end)
  end

  # Runtime-artifact footprint the child would create IF it wrongly targeted the
  # checkout (pre-#40 layout). Pattern-scoped to the child run_id shape
  # (`mut-<ts>-<rand>`) so pre-existing junk from other tests is ignored and the
  # before/after diff stays meaningful.
  defp checkout_tmp_footprint do
    [
      Path.join(@checkout, "tmp/mut_work/mut-*"),
      Path.join(@checkout, "tmp/mut_sandboxes/mut-*"),
      Path.join(@checkout, "tmp/mut_baseline-mut-*.log")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> MapSet.new()
  end

  defp tmp_project!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp write_build_path_probe!(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule BuildPathApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :build_path_app,
          version: "0.1.0",
          elixir: "~> 1.19",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:mutalisk, path: #{inspect(@checkout)}, only: :test, runtime: false}
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/build_path_app.ex"), """
    defmodule BuildPathApp do
      def add(a, b), do: a + b
      def label(true), do: :yes
      def label(false), do: :no
      def fixture_path(name), do: Application.app_dir(:build_path_app, name)
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/build_path_app_test.exs"), """
    defmodule BuildPathAppTest do
      use ExUnit.Case

      test "label" do
        assert BuildPathApp.add(1, 2) == 3
        assert BuildPathApp.label(true) == :yes
        assert BuildPathApp.label(false) == :no
      end

      test "fixture created under _build/test is readable through Application.app_dir" do
        fixture = Path.join(["_build", "test", "lib", "build_path_app", "fixture.txt"])
        File.mkdir_p!(Path.dirname(fixture))
        File.write!(fixture, "ok")

        assert File.read!(BuildPathApp.fixture_path("fixture.txt")) == "ok"
      end
    end
    """)
  end

  defp write_custom_apps_path_umbrella!(root) do
    File.mkdir_p!(Path.join([root, "packages", "core", "lib"]))
    File.mkdir_p!(Path.join([root, "packages", "core", "test"]))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule CustomAppsPathUmbrella.MixProject do
      use Mix.Project

      def project do
        [
          apps_path: "packages",
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
        [
          {:mutalisk, path: #{inspect(@checkout)}, only: :test, runtime: false}
        ]
      end
    end
    """)

    File.write!(Path.join([root, "packages", "core", "mix.exs"]), """
    defmodule Core.MixProject do
      use Mix.Project

      def project do
        [
          app: :core,
          version: "0.1.0",
          elixir: "~> 1.19"
        ]
      end
    end
    """)

    File.write!(Path.join([root, "packages", "core", "lib", "core.ex"]), """
    defmodule Core do
      def flag?(a, b), do: a || b
    end
    """)

    File.write!(
      Path.join([root, "packages", "core", "test", "test_helper.exs"]),
      "ExUnit.start()\n"
    )

    File.write!(Path.join([root, "packages", "core", "test", "core_test.exs"]), """
    defmodule CoreTest do
      use ExUnit.Case

      test "flag" do
        assert Core.flag?(true, false)
      end
    end
    """)
  end

  defp write_configured_history_probe!(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule ConfiguredHistoryPath.MixProject do
      use Mix.Project

      def project do
        [
          app: :configured_history_path,
          version: "0.1.0",
          elixir: "~> 1.19",
          deps: deps()
        ]
      end

      defp deps do
        [
          {:mutalisk, path: #{inspect(@checkout)}, only: :test, runtime: false}
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/configured_history_path.ex"), """
    defmodule ConfiguredHistoryPath do
      def multiply(a, b), do: a * b
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/configured_history_path_test.exs"), """
    defmodule ConfiguredHistoryPathTest do
      use ExUnit.Case

      test "multiply" do
        assert ConfiguredHistoryPath.multiply(2, 3) == 6
      end
    end
    """)

    File.write!(Path.join(root, ".mutalisk.exs"), """
    [
      selection: :static,
      files: "lib/configured_history_path.ex",
      max_mutants: 1,
      fail_at: 0.0,
      reporters: [:terminal],
      concurrency: 1,
      history_path: "tmp/custom-history.json"
    ]
    """)
  end

  # Per-project artifact roots to delete: the `<tmp>/mutalisk/<slug>` prefix of
  # each retained path, plus the root computed the same way `Mix.Tasks.Mut`
  # derives it (belt-and-suspenders in case the run aborted before printing).
  defp artifact_roots_to_clean(retained) do
    from_paths =
      retained
      |> Enum.map(&artifact_root_of/1)
      |> Enum.reject(&is_nil/1)

    [expected_artifact_root() | from_paths] |> Enum.uniq()
  end

  defp artifact_root_of(path) do
    case String.split(path, "/mutalisk/", parts: 2) do
      [prefix, rest] -> Path.join([prefix, "mutalisk", rest |> Path.split() |> hd()])
      _ -> nil
    end
  end

  # Mirror of `Mix.Tasks.Mut.artifact_root/1`'s slug derivation.
  defp expected_artifact_root do
    slug =
      :sha256
      |> :crypto.hash(Path.expand(@target))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    Path.join([canonical(System.tmp_dir!()), "mutalisk", slug])
  end

  # Resolve symlinks (macOS: /var -> /private/var) so comparisons against the
  # child's physical artifact paths agree — mirrors `Mut`'s `canonical_path/1`.
  defp canonical(path) do
    {:ok, cwd} = File.cwd()

    try do
      File.cd!(path)
      File.cwd!()
    after
      File.cd!(cwd)
    end
  end
end
