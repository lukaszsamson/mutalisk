defmodule Mut.TestRuntimeTest do
  use ExUnit.Case, async: true

  alias Mut.TestRuntime

  test "aggregates formatter durations by test file in milliseconds" do
    jsonl = """
    {"event":"test_finished","module":"ArithTest","file":"test/arith_test.exs","test":"a","status":"passed","duration_us":1200}
    {"event":"test_finished","module":"ArithTest","file":"test/arith_test.exs","test":"b","status":"passed","duration_us":800}
    {"event":"suite_finished","total":2,"failed":0,"passed":2,"skipped":0}
    """

    assert TestRuntime.from_formatter_output(jsonl) == %{{:file, "test/arith_test.exs"} => 2}
  end
end
