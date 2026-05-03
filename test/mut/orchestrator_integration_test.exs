defmodule Mut.OrchestratorIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  @fixture_root Path.expand("test/fixtures/demo_app")
  @golden Path.expand("test/golden/plan/demo_app_stable_ids.json")

  test "demo_app plan matches stable-id golden" do
    assert {:ok, oracle} = Mut.OracleBuild.run(@fixture_root, run_id: "m5-plan-golden")
    plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    assert length(plan.schema) == 27
    assert plan.fallback == []
    assert plan.invalid == []

    assert Enum.frequencies_by(plan.skipped, & &1.reason) == %{
             attribute_engine_disabled: 1,
             guard_engine_disabled: 3,
             unsupported_dispatch: 2
           }

    stable_ids = plan.schema |> Enum.map(& &1.stable_id) |> Enum.sort()

    if System.get_env("MUT_REGOLD") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, Jason.encode!(stable_ids, pretty: true) <> "\n")
    end

    assert stable_ids == Jason.decode!(File.read!(@golden))
  end
end
