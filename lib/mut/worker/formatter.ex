defmodule Mut.Worker.Formatter do
  @moduledoc "ExUnit formatter emitting per-test JSONL events."
  use GenServer

  import ExUnit.Formatter, only: [format_test_failure: 5]

  @type test_result :: %{
          module: String.t(),
          test: String.t(),
          status: String.t(),
          duration_us: non_neg_integer,
          error: String.t() | nil
        }

  @type parsed :: %{
          tests: [test_result],
          summary: map
        }

  @impl GenServer
  def init(_opts), do: {:ok, %{tests: 0, failed: 0, skipped: 0}}

  @impl GenServer
  def handle_cast({:test_started, %ExUnit.Test{} = test}, state) do
    emit(%{event: "test_started", module: inspect(test.module), test: test_name(test)})
    {:noreply, state}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    status = status(test)
    emit(test_finished_event(test, status))

    {:noreply,
     %{
       state
       | tests: state.tests + 1,
         failed: state.failed + if(status == "failed", do: 1, else: 0),
         skipped: state.skipped + if(status == "skipped", do: 1, else: 0)
     }}
  end

  def handle_cast({:suite_finished, _times_us}, state) do
    emit(%{
      event: "suite_finished",
      total: state.tests,
      failed: state.failed,
      passed: state.tests - state.failed - state.skipped,
      skipped: state.skipped
    })

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @spec parse_output(binary) :: parsed | :error
  def parse_output(raw) when is_binary(raw) do
    events =
      raw
      |> String.split("\n")
      |> Enum.flat_map(&decode_line/1)

    summary = Enum.find(events, &(&1["event"] == "suite_finished"))

    if summary do
      %{tests: test_events(events), summary: drop_event(summary)}
    else
      :error
    end
  end

  defp test_finished_event(test, status) do
    %{
      event: "test_finished",
      module: inspect(test.module),
      test: test_name(test),
      file: test_file(test),
      status: status,
      duration_us: test.time || 0
    }
    |> maybe_put_error(test)
  end

  defp maybe_put_error(event, %ExUnit.Test{state: {:failed, failures}} = test) do
    Map.put(event, :error, format_failures(test, failures))
  end

  defp maybe_put_error(event, _test), do: event

  defp status(%ExUnit.Test{state: nil}), do: "passed"
  defp status(%ExUnit.Test{state: {:skipped, _reason}}), do: "skipped"
  defp status(%ExUnit.Test{state: {:excluded, _reason}}), do: "skipped"
  defp status(%ExUnit.Test{state: {:failed, _failures}}), do: "failed"
  defp status(%ExUnit.Test{state: {:invalid, _reason}}), do: "failed"

  defp test_name(%ExUnit.Test{tags: %{test: test}}),
    do: test |> Atom.to_string() |> String.trim_leading("test ")

  defp test_name(%ExUnit.Test{name: name}), do: Atom.to_string(name)
  defp test_file(%ExUnit.Test{tags: %{file: file}}), do: file

  defp emit(event) do
    event
    |> Jason.encode!()
    |> IO.puts()
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => _event} = event} -> [event]
      _not_json -> []
    end
  end

  defp test_events(events) do
    events
    |> Enum.filter(&(&1["event"] == "test_finished"))
    |> Enum.map(&drop_event/1)
  end

  defp drop_event(event), do: Map.delete(event, "event")

  defp format_failures(test, failures) do
    format_test_failure(test, failures, 1, 80, fn _key, value -> value end)
  rescue
    exception -> Exception.message(exception)
  end
end
