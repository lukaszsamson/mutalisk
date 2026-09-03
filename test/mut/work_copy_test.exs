defmodule Mut.WorkCopyTest do
  use ExUnit.Case, async: false

  @moduledoc false

  test "materializes a project and symlinks stable inputs" do
    root = tmp_dir("project")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, "tmp"))

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Tiny.MixProject do\n  use Mix.Project\n  def project, do: [app: :tiny, version: \"0.1.0\"]\nend\n"
    )

    File.write!(Path.join(root, "mix.lock"), "%{}")
    File.write!(Path.join(root, "lib/tiny.ex"), "defmodule Tiny, do: nil\n")

    {:ok, stat_before} = File.stat(Path.join(root, "lib/tiny.ex"), time: :posix)

    assert {:ok, work_copy} =
             Mut.WorkCopy.materialize(root, unique_run_id("work-copy"), force: true)

    assert File.exists?(Path.join(work_copy, "mix.exs"))
    assert File.exists?(Path.join(work_copy, "lib/tiny.ex"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(work_copy, "deps"))
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(work_copy, "mix.lock"))
    refute File.exists?(Path.join(work_copy, "_build"))
    refute File.exists?(Path.join(work_copy, "tmp"))

    {:ok, stat_after} = File.stat(Path.join(root, "lib/tiny.ex"), time: :posix)
    assert stat_after.mtime == stat_before.mtime
  end

  test "install_overlay refuses repeated install" do
    root = tmp_dir("overlay")

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Tiny.MixProject do\n  use Mix.Project\n  def project, do: [app: :tiny, version: \"0.1.0\"]\nend\n"
    )

    assert {:ok, work_copy} =
             Mut.WorkCopy.materialize(root, unique_run_id("overlay"), force: true)

    assert :ok = Mut.WorkCopy.install_overlay(work_copy, :oracle)

    assert_raise RuntimeError, ~r/overlay already installed/, fn ->
      Mut.WorkCopy.install_overlay(work_copy, :oracle)
    end
  end

  test "removes the copied project when a post-copy step fails (T29)" do
    root = tmp_dir("post_copy_failure")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "mix.exs"), "mix")
    File.write!(Path.join(root, "lib/tiny.ex"), "defmodule Tiny, do: nil\n")

    run_id = unique_run_id("post-copy-failure")
    work_copy = Path.expand(Path.join([File.cwd!(), "tmp", "mut_work", run_id]))

    assert {:error, :injected_overlay_failure} =
             Mut.WorkCopy.materialize(root, run_id,
               force: true,
               post_copy: fn copy ->
                 assert File.exists?(Path.join(copy, "lib/tiny.ex"))
                 {:error, :injected_overlay_failure}
               end
             )

    refute File.exists?(work_copy)

    # `keep_failed: true` keeps it for debugging.
    keep_run_id = unique_run_id("post-copy-keep")
    keep_copy = Path.expand(Path.join([File.cwd!(), "tmp", "mut_work", keep_run_id]))

    assert {:error, :injected_overlay_failure} =
             Mut.WorkCopy.materialize(root, keep_run_id,
               force: true,
               keep_failed: true,
               post_copy: fn _copy -> {:error, :injected_overlay_failure} end
             )

    assert File.exists?(keep_copy)
    File.rm_rf!(keep_copy)
  end

  test "does not remove a pre-existing destination it refused to overwrite (T29)" do
    root = tmp_dir("existing_destination")
    File.write!(Path.join(root, "mix.exs"), "mix")

    run_id = unique_run_id("existing")
    work_copy = Path.expand(Path.join([File.cwd!(), "tmp", "mut_work", run_id]))
    File.mkdir_p!(work_copy)
    File.write!(Path.join(work_copy, "precious.txt"), "keep me")

    assert {:error, {:already_exists, ^work_copy}} = Mut.WorkCopy.materialize(root, run_id)
    assert File.read!(Path.join(work_copy, "precious.txt")) == "keep me"
    File.rm_rf!(work_copy)
  end

  defp tmp_dir(name) do
    dir = Path.expand(Path.join(["tmp", "tests", "work_copy", name]))
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp unique_run_id(name) do
    "unit-#{name}-#{System.unique_integer([:positive])}"
  end
end
