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

  test "parse_output returns error without suite_finished" do
    assert :error = Formatter.parse_output(~s({"event":"test_finished"}\n))
  end
end
