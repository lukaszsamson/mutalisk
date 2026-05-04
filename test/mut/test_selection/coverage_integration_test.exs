defmodule Mut.TestSelection.CoverageIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :integration_schema

  alias Mut.Coverage.Runner
  alias Mut.TestSelection.Coverage
  alias Mut.TestSelection.Static

  test "demo_app coverage oracle selects exact line tests for mutants" do
    fixture = Path.expand("../../fixtures/demo_app", __DIR__)
    run_id = "coverage-selection-#{System.unique_integer([:positive])}"

    {:ok, _oracle} = Mut.OracleBuild.run(fixture, run_id: run_id, force: true, keep: true)
    work_copy = Path.expand(Path.join(["tmp", "mut_work", run_id]))

    try do
      assert {:ok, _count} =
               Mut.Oracle.load_jsonl(
                 Path.join([work_copy, "_build", "mut_oracle", ".mut_oracle.jsonl"])
               )

      oracle = Mut.Oracle.snapshot()
      plan = Mut.Orchestrator.plan(work_copy, oracle)
      test_paths = [Path.join(work_copy, "test")]
      static = Static.analyze(test_paths)

      assert {:ok, coverage_oracle} =
               Runner.run(work_copy, test_paths: test_paths, mutalisk_path: Path.expand("."))

      selection =
        Coverage.for_plan(plan, coverage_oracle, static,
          all_test_files: Mut.TestSelection.discover_test_files(test_paths)
        )

      arith =
        Enum.find(plan.schema, fn mutant ->
          mutant.file == "lib/arith.ex" and mutant.line == 5 and mutant.module == Arith
        end)

      assert %{match_kind: :exact_line, test_files: [test_file]} = selection[arith.stable_id]
      assert Path.relative_to(test_file, work_copy) == "test/arith_test.exs"

      distribution = selection |> Map.values() |> Enum.frequencies_by(& &1.match_kind)
      assert Map.get(distribution, :exact_line, 0) > 0
    after
      File.rm_rf!(work_copy)
    end
  end
end
