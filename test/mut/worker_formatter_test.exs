defmodule Mut.Worker.FormatterTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "parse_output extracts JSONL tests and summary" do
    raw = """
    Running ExUnit with seed: 1
    {"event":"test_started","module":"ArithTest","test":"score"}
    {"event":"test_finished","module":"ArithTest","test":"score","status":"failed","duration_us":12,"error":"assertion"}
    {"event":"test_finished","module":"BoolTest","test":"strict","status":"passed","duration_us":7}
    {"event":"suite_finished","total":2,"failed":1,"passed":1,"skipped":0}
    """

    assert %{
             tests: [failed, passed],
             summary: %{"total" => 2, "failed" => 1, "passed" => 1, "skipped" => 0}
           } = Mut.Worker.Formatter.parse_output(raw)

    assert failed["module"] == "ArithTest"
    assert failed["status"] == "failed"
    assert passed["test"] == "strict"
  end

  test "parse_output returns error without suite_finished" do
    assert :error = Mut.Worker.Formatter.parse_output("{\"event\":\"test_finished\"}\n")
  end
end
