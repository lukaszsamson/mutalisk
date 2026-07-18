defmodule Mut.Selection.DowngradeHintTest do
  use ExUnit.Case, async: true

  alias Mut.History.Digest
  alias Mut.Selection.DowngradeHint

  @tmp_root Path.join(System.tmp_dir!(), "mut_downgrade_hint_test")

  setup do
    dir = Path.join(@tmp_root, "case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "path/1 is under the target project's _build/", %{dir: dir} do
    assert DowngradeHint.path(dir) == Path.join([dir, "_build", "mut_selection_downgrade.json"])
  end

  test "check/1 with no hint file returns :collect", %{dir: dir} do
    assert DowngradeHint.check(dir) == :collect
    assert DowngradeHint.read(dir) == :absent
  end

  test "write/read roundtrip persists the downgrade fields", %{dir: dir} do
    digest = Digest.project_digest(dir)

    assert :ok =
             DowngradeHint.write(dir, %{
               coverage_wall_ms: 48_123,
               baseline_tests_ms: 1_200,
               project_digest: digest
             })

    assert File.exists?(DowngradeHint.path(dir))
    assert {:ok, hint} = DowngradeHint.read(dir)
    assert hint["coverage_wall_ms"] == 48_123
    assert hint["baseline_tests_ms"] == 1_200
    assert hint["project_digest"] == digest
    assert hint["format_version"] == 1
    assert is_binary(hint["tool_version"])
    assert is_binary(hint["recorded_at"])
  end

  test "check/1 returns {:skip, hint} when the digest matches the current project", %{dir: dir} do
    digest = Digest.project_digest(dir)

    :ok =
      DowngradeHint.write(dir, %{
        coverage_wall_ms: 48_000,
        baseline_tests_ms: 900,
        project_digest: digest
      })

    assert {:skip, hint} = DowngradeHint.check(dir)
    assert hint["project_digest"] == digest
  end

  test "check/1 discards a stale hint (project changed) and returns :collect", %{dir: dir} do
    digest_before = Digest.project_digest(dir)

    :ok =
      DowngradeHint.write(dir, %{
        coverage_wall_ms: 48_000,
        baseline_tests_ms: 900,
        project_digest: digest_before
      })

    # Change the project: add a source file so `project_digest/1` differs.
    File.write!(Path.join(dir, "lib/new_module.ex"), "defmodule New do\nend\n")
    refute Digest.project_digest(dir) == digest_before

    assert DowngradeHint.check(dir) == :collect
    # Stale hint is removed as a side effect so it doesn't linger.
    refute File.exists?(DowngradeHint.path(dir))
    assert DowngradeHint.read(dir) == :absent
  end

  test "read/1 ignores a corrupt (non-JSON) hint file", %{dir: dir} do
    path = DowngradeHint.path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json { at all")

    assert DowngradeHint.read(dir) == :absent
    assert DowngradeHint.check(dir) == :collect
  end

  test "read/1 ignores a hint with an unknown format_version", %{dir: dir} do
    path = DowngradeHint.path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Mut.JSON.encode!(%{"format_version" => 999, "project_digest" => "x"}))

    assert DowngradeHint.read(dir) == :absent
    assert DowngradeHint.check(dir) == :collect
  end

  test "write/2 overwrites a previous hint", %{dir: dir} do
    digest = Digest.project_digest(dir)

    :ok =
      DowngradeHint.write(dir, %{
        coverage_wall_ms: 1,
        baseline_tests_ms: 1,
        project_digest: digest
      })

    :ok =
      DowngradeHint.write(dir, %{
        coverage_wall_ms: 99_999,
        baseline_tests_ms: 500,
        project_digest: digest
      })

    assert {:ok, hint} = DowngradeHint.read(dir)
    assert hint["coverage_wall_ms"] == 99_999
  end

  test "delete/1 removes the hint file and is a no-op when absent", %{dir: dir} do
    digest = Digest.project_digest(dir)

    :ok =
      DowngradeHint.write(dir, %{
        coverage_wall_ms: 1,
        baseline_tests_ms: 1,
        project_digest: digest
      })

    assert File.exists?(DowngradeHint.path(dir))
    assert :ok = DowngradeHint.delete(dir)
    refute File.exists?(DowngradeHint.path(dir))
    # Calling again on an already-absent file must not raise.
    assert :ok = DowngradeHint.delete(dir)
  end

  test "write/2 returns {:error, reason} instead of raising when the path is unwritable", %{
    dir: dir
  } do
    # Make `_build` a regular file so `File.mkdir_p!(Path.dirname(path))` (which
    # needs `_build/` to be a directory) fails.
    build_path = Path.join(dir, "_build")
    File.write!(build_path, "not a directory")

    assert {:error, _reason} =
             DowngradeHint.write(dir, %{
               coverage_wall_ms: 1,
               baseline_tests_ms: 1,
               project_digest: "abc"
             })
  end
end
