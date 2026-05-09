defmodule Mut.Trace.WriterTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Oracle.DispatchSite
  alias Mut.Trace.Writer

  test "writes dispatch sites and close sentinel" do
    path = Path.expand("tmp/tests/trace_writer/oracle.jsonl")
    File.rm_rf!(Path.dirname(path))

    start_supervised!({Writer, jsonl_path: path})

    Writer.put(site(1))
    Writer.put(site(2))
    assert :ok = Writer.close_with_count()

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 3
    assert Mut.JSON.decode!(List.last(lines)) == %{"event" => "end", "count" => 2}
  end

  defp site(line) do
    %DispatchSite{
      file: "lib/example.ex",
      line: line,
      dispatch_kind: :remote_function,
      resolved_module: Kernel,
      resolved_name: :+,
      resolved_arity: 2,
      event_file: "lib/example.ex"
    }
  end
end
