defmodule Mut.MixManifestTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.MixManifest

  test "read parses the real demo_app schema manifest" do
    manifest_path = real_manifest_path()

    assert {:ok, %MixManifest{} = manifest} = MixManifest.read(manifest_path)
    assert manifest.version == 34
    assert manifest.modules[Guards] == "lib/guards.ex"
    assert manifest.sources["lib/guards.ex"].compile_deps == [Module, Kernel]
    assert manifest.sources["lib/guards.ex"].runtime_deps == [:erlang]
  end

  test "version_assertion raises clearly on unknown shape" do
    assert_raise ArgumentError, ~r/pinned to Elixir 1\.20-rc\.4 manifest version 34/, fn ->
      MixManifest.version_assertion({33, %{}, %{}})
    end
  end

  test "read reports corrupted manifests as errors" do
    root = Path.expand("tmp/tests/mix_manifest/corrupt")
    path = Path.join(root, "compile.elixir")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(path, :erlang.term_to_binary({33, %{}, %{}}))

    assert {:error, {ArgumentError, message}} = MixManifest.read(path)
    assert message =~ "manifest version 34"
  end

  test "dependents traverses compile deps transitively and direct export/struct deps only" do
    manifest = %MixManifest{
      version: 34,
      modules: %{
        A => "lib/a.ex",
        B => "lib/b.ex",
        C => "lib/c.ex",
        D => "lib/d.ex",
        E => "lib/e.ex"
      },
      sources: %{
        "lib/a.ex" => deps(),
        "lib/b.ex" => deps(compile_deps: [A]),
        "lib/c.ex" => deps(compile_deps: [B]),
        "lib/d.ex" => deps(export_deps: [A], runtime_deps: [C]),
        "lib/e.ex" => deps(struct_deps: [A], runtime_deps: [A])
      }
    }

    assert MixManifest.dependents(manifest, [A], [:compile]) ==
             MapSet.new(["lib/b.ex", "lib/c.ex"])

    assert MixManifest.dependents(manifest, [A], [:export]) == MapSet.new(["lib/d.ex"])
    assert MixManifest.dependents(manifest, [A], [:struct]) == MapSet.new(["lib/e.ex"])
    assert MixManifest.dependents(manifest, [A], [:runtime]) == MapSet.new(["lib/e.ex"])

    assert MixManifest.dependents(manifest, [A], [:compile, :export, :struct]) ==
             MapSet.new(["lib/b.ex", "lib/c.ex", "lib/d.ex", "lib/e.ex"])
  end

  test "dependents excludes the mutated module source" do
    manifest = %MixManifest{
      version: 34,
      modules: %{A => "lib/a.ex"},
      sources: %{"lib/a.ex" => deps(compile_deps: [A])}
    }

    assert MixManifest.dependents(manifest, [A], [:compile]) == MapSet.new()
  end

  defp real_manifest_path do
    {:ok, oracle} =
      Mut.OracleBuild.run(fixture_root(), run_id: "m10-manifest-oracle", force: true)

    plan = Mut.Orchestrator.plan(fixture_root(), oracle)

    {:ok, result} =
      Mut.SchemaBuild.build(plan,
        user_project_root: fixture_root(),
        run_id: "m10-manifest-schema",
        force: true,
        keep: true
      )

    on_exit(fn -> File.rm_rf!(result.work_copy_root) end)
    Path.join(result.work_copy_root, "_build/mut_schema/lib/demo_app/.mix/compile.elixir")
  end

  defp fixture_root, do: Path.expand("test/fixtures/demo_app")

  defp deps(attrs \\ []) do
    defaults = [compile_deps: [], export_deps: [], struct_deps: [], runtime_deps: []]
    defaults |> Keyword.merge(attrs) |> Map.new()
  end
end
