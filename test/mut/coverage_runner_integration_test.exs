defmodule Mut.CoverageRunnerIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Coverage.Runner

  @tag :integration_schema
  test "collects demo_app line and function coverage per test file" do
    run_id = "coverage-runner-#{System.unique_integer([:positive])}"
    fixture = Path.expand("../fixtures/demo_app", __DIR__)

    {:ok, work_copy} = Mut.WorkCopy.materialize(fixture, run_id, force: true)

    try do
      :ok = Mut.WorkCopy.install_overlay(work_copy, :schema)

      assert {:ok, oracle} =
               Runner.run(work_copy,
                 test_paths: ["test"],
                 timeout_per_file_ms: 60_000
               )

      canary = {:file, "test/arith_test.exs"}

      assert MapSet.member?(Map.fetch!(oracle.by_line, {"lib/arith.ex", 5}), canary)
      assert MapSet.member?(Map.fetch!(oracle.by_function, {Arith, :score, 2}), canary)
      assert map_size(oracle.test_runtime_ms) == 6
      assert oracle.collection_wall_ms > 0
    after
      File.rm_rf!(work_copy)
    end
  end
end
