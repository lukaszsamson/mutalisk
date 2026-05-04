defmodule Mut.MemoryWatchdog do
  @moduledoc """
  Periodically appends BEAM memory stats to a log file.

  Useful for diagnosing slow leaks during long-running benches. Cheap
  (one `:erlang.memory/0` snapshot every interval) and process-isolated
  so it cannot contribute to the leak it is observing.
  """

  @default_interval_ms 5_000

  @spec start(Path.t(), keyword) :: {:ok, pid} | {:error, term}
  def start(log_path, opts \\ []) when is_binary(log_path) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    File.mkdir_p!(Path.dirname(log_path))

    case File.open(log_path, [:write, :binary, :raw]) do
      {:ok, io} ->
        write_header(io)
        # Intentionally NOT linked: shutting down the watchdog must never
        # propagate exit signals to the orchestrator process. The BEAM
        # exits when `mix mut` returns, so leak risk is bounded.
        pid = spawn(fn -> loop(io, interval, System.monotonic_time(:millisecond)) end)
        {:ok, pid}

      {:error, _reason} = err ->
        err
    end
  end

  @spec stop(pid) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp loop(io, interval, started_ms) do
    sample(io, started_ms)

    receive do
      :stop -> :ok
    after
      interval ->
        loop(io, interval, started_ms)
    end
  end

  defp write_header(io) do
    :file.write(
      io,
      "# elapsed_ms\ttotal_mb\tprocesses_mb\tbinary_mb\tets_mb\tatom_mb\tprocess_count\n"
    )
  end

  defp sample(io, started_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_ms
    mem = :erlang.memory()

    line =
      [
        Integer.to_string(elapsed),
        mb(mem[:total]),
        mb(mem[:processes]),
        mb(mem[:binary]),
        mb(mem[:ets]),
        mb(mem[:atom]),
        Integer.to_string(:erlang.system_info(:process_count))
      ]
      |> Enum.join("\t")

    :file.write(io, line <> "\n")
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mb(bytes) when is_integer(bytes) do
    :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
  end

  defp mb(_), do: "0.0"
end
