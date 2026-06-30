defmodule Mut.CoverageRunnerTest do
  use ExUnit.Case, async: true

  alias Mut.Coverage.Runner
  alias Mut.CoverageOracle

  test "collection budget caps the next per-file timeout and degrades unvisited files" do
    root = "/work/copy"

    files = [
      "/work/copy/test/a_test.exs",
      "/work/copy/test/b_test.exs",
      "/work/copy/test/c_test.exs"
    ]

    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn _root, test_file, timeout_ms, _mutalisk_path ->
      Agent.update(calls, &[{Path.basename(test_file), timeout_ms} | &1])
      Agent.update(clock, fn _ -> 12 end)
      {:ok, %CoverageOracle{test_runtime_ms: %{{:file, "test/a_test.exs"} => 5}}}
    end

    assert {:ok, oracle} =
             Runner.collect_files_for_test(files, root,
               timeout_per_file_ms: 60_000,
               collection_budget_ms: 10,
               runner: runner,
               clock: fn -> Agent.get(clock, & &1) end
             )

    assert Agent.get(calls, &Enum.reverse/1) == [{"a_test.exs", 10}]

    assert oracle.degraded_test_files == [
             {"test/b_test.exs", {:coverage_collection_budget_exceeded, "test/b_test.exs", 10}},
             {"test/c_test.exs", {:coverage_collection_budget_exceeded, "test/c_test.exs", 10}}
           ]
  end

  test "without collection budget every file is attempted" do
    root = "/work/copy"
    files = ["/work/copy/test/a_test.exs", "/work/copy/test/b_test.exs"]
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn _root, test_file, timeout_ms, _mutalisk_path ->
      Agent.update(calls, &[{Path.basename(test_file), timeout_ms} | &1])
      {:error, :coverage_failed}
    end

    assert {:ok, oracle} =
             Runner.collect_files_for_test(files, root,
               timeout_per_file_ms: 123,
               runner: runner,
               clock: fn -> 0 end
             )

    assert Agent.get(calls, &Enum.reverse/1) == [{"a_test.exs", 123}, {"b_test.exs", 123}]

    assert oracle.degraded_test_files == [
             {"test/a_test.exs", :coverage_failed},
             {"test/b_test.exs", :coverage_failed}
           ]
  end
end
