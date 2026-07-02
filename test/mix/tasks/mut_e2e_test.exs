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
