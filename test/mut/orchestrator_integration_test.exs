defmodule Mut.OrchestratorIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  @fixture_root Path.expand("test/fixtures/demo_app")
  @golden Path.expand("test/golden/plan/demo_app_stable_ids.json")

  test "demo_app plan matches stable-id golden" do
    oracle = build_or_load_oracle()
    plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    assert length(plan.schema) == 30
    assert plan.fallback == []

    assert Enum.frequencies_by(plan.skipped, & &1.reason) == %{
             attribute_engine_disabled: 1,
             guard_engine_disabled: 3,
             missing_oracle_site: 2
           }

    stable_ids = plan.schema |> Enum.map(& &1.stable_id) |> Enum.sort()

    if System.get_env("MUT_REGOLD") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, Jason.encode!(stable_ids, pretty: true) <> "\n")
    end

    assert stable_ids == Jason.decode!(File.read!(@golden))
  end

  defp build_or_load_oracle do
    case Mut.OracleBuild.run(@fixture_root, run_id: "m5-plan-golden") do
      {:ok, oracle} -> oracle
      _error -> Mut.FixtureOracleHelper.golden_oracle()
    end
  end
end
