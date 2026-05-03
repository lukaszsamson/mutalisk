defmodule Mut.SchemaBuildTest do
  use ExUnit.Case, async: false

  @moduledoc false

  test "snapshot returns sorted relative paths with sha256 hashes" do
    root = Path.expand("tmp/schema_build_snapshot_test")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "b"))
    File.write!(Path.join(root, "b/two.beam"), "two")
    File.write!(Path.join(root, "one.beam"), "one")
    on_exit(fn -> File.rm_rf!(root) end)

    snapshot = Mut.SchemaBuild.snapshot(root)

    assert Map.keys(snapshot) == ["b/two.beam", "one.beam"]
    assert Enum.all?(snapshot, fn {_path, hash} -> hash =~ ~r/\A[0-9a-f]{64}\z/ end)
  end
end
