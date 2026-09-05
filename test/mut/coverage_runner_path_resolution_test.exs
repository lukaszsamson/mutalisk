defmodule Mut.CoverageRunnerPathResolutionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  T33 regression: `discover_test_files/2` must resolve a relative test path
  against the work-copy root FIRST, and only fall back to the bare path when
  the root-joined path does not exist. Runs with `async: false` because it
  changes the OS process's current working directory.
  """

  alias Mut.Coverage.Runner

  test "resolves a relative path against the work-copy root before the host cwd" do
    tmp_base = Path.join(System.tmp_dir!(), "mut_t33_#{System.unique_integer([:positive])}")
    root = Path.join(tmp_base, "root")
    other_cwd = Path.join(tmp_base, "other_cwd")

    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(other_cwd, "test"))
    File.write!(Path.join(root, "test/foo_test.exs"), "root copy")
    File.write!(Path.join(other_cwd, "test/foo_test.exs"), "other copy")

    original_cwd = File.cwd!()
    File.cd!(other_cwd)

    try do
      assert Runner.discover_test_files(root, ["test/foo_test.exs"]) == [
               Path.join(root, "test/foo_test.exs")
             ]
    after
      File.cd!(original_cwd)
      File.rm_rf!(tmp_base)
    end
  end

  test "falls back to the bare path when it does not exist under the root" do
    tmp_base =
      Path.join(System.tmp_dir!(), "mut_t33_fallback_#{System.unique_integer([:positive])}")

    root = Path.join(tmp_base, "root")
    other_cwd = Path.join(tmp_base, "other_cwd")

    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(other_cwd, "test"))
    File.write!(Path.join(other_cwd, "test/foo_test.exs"), "only in cwd")

    original_cwd = File.cwd!()
    File.cd!(other_cwd)

    try do
      assert Runner.discover_test_files(root, ["test/foo_test.exs"]) == [
               "test/foo_test.exs"
             ]
    after
      File.cd!(original_cwd)
      File.rm_rf!(tmp_base)
    end
  end
end
