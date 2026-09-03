defmodule Mut.Worker.FormatterTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Worker.Formatter

  test "parse_output extracts JSONL tests and summary" do
    raw =
      [
        "Running ExUnit with seed: 1",
        ~s({"event":"test_started","module":"ArithTest","test":"score"}),
        ~s({"event":"test_finished","module":"ArithTest","test":"score","status":"failed","duration_us":12,"error":"assertion"}),
        ~s({"event":"test_finished","module":"BoolTest","test":"strict","status":"passed","duration_us":7}),
        ~s({"event":"suite_finished","total":2,"failed":1,"passed":1,"skipped":0})
      ]
      |> Enum.join("\n")

    assert %{
             tests: [failed, passed],
             summary: %{"total" => 2, "failed" => 1, "passed" => 1, "skipped" => 0}
           } = Formatter.parse_output(raw)

    assert failed["module"] == "ArithTest"
    assert failed["status"] == "failed"
    assert passed["test"] == "strict"
  end

  # T30: `total` includes skipped/excluded tests, so it cannot distinguish a
  # green suite from one where nothing executed. `ran` can, and is summed across
  # umbrella child suites like the other counters.
  test "parse_output surfaces the ran count and merges it across umbrella suites" do
    raw =
      [
        ~s({"event":"suite_finished","total":3,"ran":1,"failed":0,"passed":1,"skipped":2}),
        ~s({"event":"suite_finished","total":2,"ran":0,"failed":0,"passed":0,"skipped":2})
      ]
      |> Enum.join("\n")

    assert %{summary: %{"total" => 5, "ran" => 1, "skipped" => 4}} = Formatter.parse_output(raw)
  end

  test "parse_output returns error without suite_finished" do
    assert :error = Formatter.parse_output(~s({"event":"test_finished"}\n))
  end
end
