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

    assert {:ok, work_copy} = Mut.WorkCopy.materialize(root, "unit-work-copy", force: true)
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

    assert {:ok, work_copy} = Mut.WorkCopy.materialize(root, "unit-overlay", force: true)
    assert :ok = Mut.WorkCopy.install_overlay(work_copy, :oracle)

    assert_raise RuntimeError, ~r/overlay already installed/, fn ->
      Mut.WorkCopy.install_overlay(work_copy, :oracle)
    end
  end

  defp tmp_dir(name) do
    dir = Path.expand(Path.join(["tmp", "tests", "work_copy", name]))
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
