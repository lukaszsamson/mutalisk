defmodule Mix.Tasks.MutReportWriteTest do
  use ExUnit.Case, async: false

  @moduledoc "T24: a report-writing failure must not destroy a completed run."

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mut, as: MutTask
  alias Mut.Reporter.StrykerJson

  test "a crash in the report writers is logged to stderr and does not propagate" do
    stderr =
      capture_io(:stderr, fn ->
        assert MutTask.safe_render(fn -> raise ArgumentError, "unencodable byte" end) == :error
      end)

    assert stderr =~ "failed to write the mutation report"
    assert stderr =~ "unencodable byte"
    assert stderr =~ "ArgumentError"
    assert stderr =~ "The run itself completed"
  end

  test "a real encoder failure (invalid UTF-8 in the report) is survivable" do
    path =
      Path.join([
        System.tmp_dir!(),
        "mut_report_write_#{System.unique_integer([:positive])}",
        "stryker.report.json"
      ])

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    rendered = %{"schemaVersion" => "2", "files" => %{"a.ex" => <<255, 254, "ok">>}}

    # Sanity: the encoder really does reject this, so the guard is load-bearing.
    assert_raise ErlangError, fn -> StrykerJson.write(rendered, path) end

    stderr =
      capture_io(:stderr, fn ->
        assert MutTask.safe_render(fn -> StrykerJson.write(rendered, path) end) == :error
      end)

    assert stderr =~ "failed to write the mutation report"
  end

  test "successful writers return :ok without touching stderr" do
    stderr = capture_io(:stderr, fn -> assert MutTask.safe_render(fn -> :written end) == :ok end)

    assert stderr == ""
  end
end
