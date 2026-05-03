defmodule Mut.RecompileTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.FallbackPatch
  alias Mut.Recompile
  alias Mut.Sandbox

  test "env matches the fallback build-path contract" do
    assert Recompile.env() == [
             {"MIX_ENV", "test"},
             {"MIX_BUILD_PATH", "_build/mut_schema"},
             {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
             {"MUTALISK_ROLE", "fallback"},
             {"MUTALISK_PATH", Path.expand(File.cwd!())}
           ]
  end

  test "recompile patches one fixture file in a real sandbox and reset restores it" do
    {:ok, schema_result} = schema_result()

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "m10-recompile-sandbox", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)
    original = File.read!(Path.join(sandbox.path, "lib/guards.ex"))
    mutant = Mut.FallbackFixture.plan().fallback |> Enum.find(&(&1.mutation_kind == :boundary))
    {:ok, patch} = FallbackPatch.render(mutant, original)
    beam = Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Guards.beam")
    before_mtime = File.stat!(beam).mtime

    :timer.sleep(1100)
    assert :ok = FallbackPatch.apply(patch, sandbox.path)
    assert :ok = Recompile.recompile(sandbox, [patch.file], [], app: "demo_app")

    assert File.stat!(beam).mtime > before_mtime
    assert File.read!(Path.join(sandbox.path, "lib/guards.ex")) =~ "x >= 0"

    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(Path.join(sandbox.path, "lib/guards.ex")) == original

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
    File.rm_rf!(schema_result.work_copy_root)
  end

  defp schema_result do
    fixture_root = Path.expand("test/fixtures/demo_app")
    {:ok, oracle} = Mut.OracleBuild.run(fixture_root, run_id: "m10-recompile-oracle", force: true)
    plan = Mut.Orchestrator.plan(fixture_root, oracle)

    Mut.SchemaBuild.build(plan,
      user_project_root: fixture_root,
      run_id: "m10-recompile-schema",
      force: true,
      keep: true
    )
  end
end
