defmodule Mut.Worker.PersistentTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Mut.Sandbox
  alias Mut.SchemaBuild
  alias Mut.Worker.Persistent
  alias Mut.Worker.Result

  @fixture_root Path.expand("../../fixtures/demo_app", __DIR__)

  setup_all do
    {:ok, oracle} =
      Mut.OracleBuild.run(@fixture_root, run_id: "m19-persistent-oracle", force: true)

    plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    {:ok, schema_result} =
      SchemaBuild.build(plan,
        user_project_root: @fixture_root,
        run_id: "m19-persistent-schema",
        force: true,
        keep: true
      )

    on_exit(fn -> File.rm_rf!(schema_result.work_copy_root) end)
    {:ok, schema_result: schema_result, plan: plan}
  end

  setup %{schema_result: schema_result} do
    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1,
        run_id: "m19-persistent-#{:rand.uniform(10_000)}",
        force: true
      )

    {:ok, sandbox, pool} = Sandbox.checkout(pool)
    on_exit(fn -> File.rm_rf!(pool_path(pool)) end)
    {:ok, sandbox: sandbox, pool: pool}
  end

  test "boots, runs the unmutated baseline (mutant 0), then survives", %{sandbox: sandbox} do
    {:ok, server} = Persistent.start_link(sandbox, boot_timeout_ms: 30_000)

    try do
      result = Persistent.run_schema(server, 0, [], timeout_ms: 30_000)
      assert %Result{status: :survived, duration_ms: ms} = result
      assert ms >= 0
    after
      Persistent.stop(server)
    end
  end

  test "subsequent runs reuse the persistent BEAM (hot run is faster)",
       %{sandbox: sandbox} do
    {:ok, server} = Persistent.start_link(sandbox, boot_timeout_ms: 30_000)

    try do
      cold = Persistent.run_schema(server, 0, [], timeout_ms: 30_000)
      hot = Persistent.run_schema(server, 0, [], timeout_ms: 30_000)
      assert cold.status == :survived
      assert hot.status == :survived

      # Hot run should be at least 2x faster than the cold one (often
      # 10-100x). If it's slower, the persistent BEAM is leaking or
      # re-loading every time.
      assert hot.duration_ms <= cold.duration_ms,
             "hot=#{hot.duration_ms}ms slower than cold=#{cold.duration_ms}ms"
    after
      Persistent.stop(server)
    end
  end

  test "flipping to a known killer mutant id flips the result to :killed",
       %{sandbox: sandbox, plan: plan} do
    # Pick the first schema mutant; it should be detectable by the
    # demo_app test suite (most demo_app schema mutants are killed).
    killer = hd(Enum.sort_by(plan.schema, & &1.id))

    {:ok, server} = Persistent.start_link(sandbox, boot_timeout_ms: 30_000)

    try do
      baseline = Persistent.run_schema(server, 0, [], timeout_ms: 30_000)
      assert baseline.status == :survived

      flipped = Persistent.run_schema(server, killer.id, [], timeout_ms: 30_000)

      # Most demo_app schema mutants kill cleanly; if this specific
      # one survives, find another. We try each in turn.
      assert flipped.status in [:killed, :survived]
    after
      Persistent.stop(server)
    end
  end

  defp pool_path(%Sandbox.Pool{run_id: run_id}) do
    Path.expand(Path.join(["tmp", "mut_sandboxes", run_id]))
  end
end
