defmodule Mut.TestRuntime do
  @moduledoc "Aggregates Mut.Worker.Formatter JSONL durations into v1.5 test runtimes."

  alias Mut.Worker.Formatter

  @spec from_formatter_output(binary) :: %{Mut.CoverageOracle.test_id() => non_neg_integer()}
  def from_formatter_output(jsonl) when is_binary(jsonl) do
    case Formatter.parse_output(jsonl) do
      %{tests: tests} ->
        tests
        |> Enum.group_by(&test_id/1)
        |> Map.new(fn {test_id, events} ->
          duration_us = Enum.reduce(events, 0, &(&2 + Map.get(&1, "duration_us", 0)))
          {test_id, div(duration_us + 999, 1000)}
        end)

      :error ->
        %{}
    end
  end

  defp test_id(%{"file" => file}) when is_binary(file), do: {:file, file}

  defp test_id(%{"module" => module}) when is_binary(module) do
    {:module, Module.concat([module])}
  end
end
