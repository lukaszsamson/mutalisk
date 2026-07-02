defmodule Mut.BuildPathCompatTest do
  use ExUnit.Case, async: true

  test "aliases conventional _build/test to the active build path" do
    root = tmp_dir()
    active = Path.join(root, "_build/mut_oracle")

    assert :ok = Mut.BuildPathCompat.alias_test_build_path(root, "_build/mut_oracle")

    fixture = Path.join([root, "_build", "test", "lib", "demo", "fixture.txt"])
    File.mkdir_p!(Path.dirname(fixture))
    File.write!(fixture, "ok")

    assert File.read!(Path.join([active, "lib", "demo", "fixture.txt"])) == "ok"
  end

  test "relinks an existing alias when the active build path changes" do
    root = tmp_dir()

    assert :ok = Mut.BuildPathCompat.alias_test_build_path(root, "_build/mut_oracle")
    assert :ok = Mut.BuildPathCompat.alias_test_build_path(root, "_build/mut_schema")

    assert File.read_link!(Path.join([root, "_build", "test"])) == "mut_schema"
  end

  defp tmp_dir do
    root =
      Path.join(System.tmp_dir!(), "mut_build_path_compat_#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
