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
    assert length(plan.fallback) == 4
    assert plan.invalid == []

    assert Enum.frequencies_by(plan.skipped, & &1.reason) == %{
             attribute_engine_disabled: 1,
             body_literal_engine_disabled: 5,
             unsupported_dispatch: 3
           }

    opt_in_plan =
      Mut.Orchestrator.plan(@fixture_root, oracle,
        enabled_targets: [:dispatch, :guard, :module_attribute]
      )

    assert length(opt_in_plan.schema) == 27
    assert length(opt_in_plan.fallback) == 6
    assert opt_in_plan.invalid == []

    assert Enum.frequencies_by(opt_in_plan.skipped, & &1.reason) == %{
             body_literal_engine_disabled: 5,
             unsupported_dispatch: 3
           }

    stable_ids =
      opt_in_plan
      |> then(&(&1.schema ++ &1.fallback))
      |> Enum.map(& &1.stable_id)
      |> Enum.sort()

    if System.get_env("MUT_REGOLD") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, Mut.JSON.encode!(stable_ids, pretty: true) <> "\n")
    end

    assert stable_ids == Mut.JSON.decode!(File.read!(@golden))
  end
end
