defmodule Mut.SandboxTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Sandbox
  alias Mut.SchemaBuild

  test "create_pool copies schema work copy and preserves symlinks" do
    schema_result = schema_result("create_pool")

    assert {:ok, pool} =
             Sandbox.create_pool(schema_result, 2, run_id: "unit-sandbox-pool", force: true)

    paths = pool.sandboxes |> Enum.map(& &1.path) |> Enum.sort()
    assert length(paths) == 2
    assert Enum.all?(paths, &File.dir?/1)
    assert Enum.all?(paths, &File.dir?(Path.join(&1, "_build/mut_schema")))
    assert Enum.all?(paths, &File.exists?(Path.join(&1, "mix.exs")))

    assert Enum.all?(
             paths,
             &match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(&1, "deps")))
           )

    assert :ok = Sandbox.destroy_pool(pool)
    refute File.exists?(Path.expand("tmp/mut_sandboxes/unit-sandbox-pool"))
  end

  test "checkout and checkin move sandboxes between pool sets" do
    schema_result = schema_result("checkout")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-checkout", force: true)

    assert {:ok, sandbox, pool} = Sandbox.checkout(pool)
    assert MapSet.member?(pool.checked_out, sandbox)
    assert {:error, :pool_empty} = Sandbox.checkout(pool)

    checked_in = Sandbox.checkin(sandbox, pool)
    assert MapSet.member?(checked_in.sandboxes, sandbox)
    refute MapSet.member?(checked_in.checked_out, sandbox)

    assert checked_in == Sandbox.checkin(sandbox, checked_in)
    Sandbox.destroy_pool(checked_in)
  end

  test "create_pool fails loudly when sandbox materialization is incomplete" do
    schema_result = schema_result("bad_materialization")
    File.rm!(Path.join(schema_result.work_copy_root, "mix.exs"))

    assert {:error, {:missing_mix_exs, path}} =
             Sandbox.create_pool(schema_result, 1,
               run_id: "unit-sandbox-bad-materialization",
               force: true
             )

    assert path =~ "unit-sandbox-bad-materialization/1"
  end

  test "reset restores corrupted baseline and source files and removes stray files" do
    schema_result = schema_result("reset")
    {:ok, pool} = Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-reset", force: true)
    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    baseline_file =
      Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")

    File.write!(baseline_file, "corrupt")
    source_file = Path.join(sandbox.path, "lib/arith.ex")
    File.write!(source_file, "corrupt source")

    File.write!(
      Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/stray.beam"),
      "stray"
    )

    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(baseline_file) == "beam"
    assert File.read!(source_file) == "defmodule Arith, do: :ok\n"
    refute File.exists?(Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/stray.beam"))

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  defp schema_result(name) do
    root = Path.expand(Path.join(["tmp", "tests", "sandbox", name, "schema"]))
    File.rm_rf!(Path.dirname(root))
    File.mkdir_p!(Path.join(root, "_build/mut_schema/lib/demo_app/ebin"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "deps_target"))
    File.write!(Path.join(root, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"), "beam")
    File.write!(Path.join(root, "lib/arith.ex"), "defmodule Arith, do: :ok\n")
    File.write!(Path.join(root, "mix.exs"), "mix")
    :ok = File.ln_s(Path.join(root, "deps_target"), Path.join(root, "deps"))

    %SchemaBuild.Result{
      work_copy_root: root,
      build_path: Path.join(root, "_build/mut_schema"),
      plan: %Mut.Plan{schema: [], fallback: [], skipped: []},
      placement_maps: %{},
      snapshot: %{
        "lib/demo_app/ebin/Elixir.Arith.beam" =>
          sha256(Path.join(root, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"))
      },
      rollback_iterations: 0,
      invalid_mutants: []
    }
  end

  defp sha256(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end
end
