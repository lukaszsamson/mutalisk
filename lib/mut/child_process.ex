defmodule Mut.ChildProcess do
  @moduledoc """
  Runs child processes with bounded output retention.

  ## Options

    * `:max_output_bytes` - cap retained in-memory output (default 256_000).
    * `:log_path` - if set, every chunk of stdout/stderr is appended to that
      file as it arrives. The in-memory buffer is still maintained (bounded by
      `:max_output_bytes`) so callers using the return value's `output` keep
      working — this is observability layered on top of the existing API.
    * `:retry_on` - list of binary substrings; if the child exits non-zero AND
      its output contains any substring, retry up to `:max_retries` times
      (default 0). Designed for transient BEAM-startup races at high
      concurrency ("Failed to load module 'elixir'", crash-dump signatures),
      not for retrying real failures. M84.
    * `:max_retries` - integer, default 0 (no retry); only consulted when
      `:retry_on` would match.
    * `:timeout_ms`, `:cd`, `:env` - as before.
  """

  @default_max_output_bytes 256_000

  @type result ::
          {:exit, non_neg_integer(), String.t()} | {:timeout, String.t()} | {:error, term()}

  @spec run(String.t(), [String.t()], keyword) :: result()
  def run(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    case executable_path(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        run_with_retries(path, args, opts, Keyword.get(opts, :max_retries, 0))
    end
  end

  defp run_with_retries(path, args, opts, attempts_left) do
    log_io = open_log(Keyword.get(opts, :log_path))

    result =
      try do
        port = open_port(path, args, opts)
        collect(port, init_state(opts, log_io), Keyword.get(opts, :timeout_ms, :infinity))
      after
        close_log(log_io)
      end

    if attempts_left > 0 and retryable?(result, Keyword.get(opts, :retry_on, [])) do
      run_with_retries(path, args, opts, attempts_left - 1)
    else
      result
    end
  end

  # Retry only on transient signatures the caller explicitly opted into; never
  # on success, timeout, or arbitrary failures (would mask real bugs).
  defp retryable?({:exit, code, output}, patterns) when code != 0 and is_list(patterns) do
    Enum.any?(patterns, &(is_binary(&1) and String.contains?(output, &1)))
  end

  defp retryable?(_result, _patterns), do: false

  @spec output_tail(String.t(), pos_integer()) :: String.t()
  def output_tail(output, lines \\ 80)
      when is_binary(output) and is_integer(lines) and lines > 0 do
    output
    |> String.split("\n")
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end

  defp executable_path(executable) do
    if Path.type(executable) == :absolute do
      executable
    else
      System.find_executable(executable)
    end
  end

  defp open_port(path, args, opts) do
    port_opts = [
      {:args, args},
      :stderr_to_stdout,
      :exit_status,
      :binary
    ]

    port_opts = maybe_put(port_opts, :cd, Keyword.get(opts, :cd))
    port_opts = maybe_put(port_opts, :env, port_env(Keyword.get(opts, :env, [])))

    Port.open({:spawn_executable, path}, port_opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]

  defp port_env(env) do
    env
    |> ensure_crash_dump_quiet()
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  # R14: disable `erl_crash.dump` for every spawned child (compile/recompile
  # phases run user code at compile time, which a mutant can crash). A caller
  # that explicitly sets the var keeps its value.
  defp ensure_crash_dump_quiet(env) do
    if List.keymember?(env, "ERL_CRASH_DUMP_SECONDS", 0) do
      env
    else
      [{"ERL_CRASH_DUMP_SECONDS", "0"} | env]
    end
  end

  defp init_state(opts, log_io) do
    %{
      output: "",
      bytes: 0,
      max_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
      log_io: log_io
    }
  end

  # Absolute monotonic deadline (R2): the budget is wall-clock from port open,
  # not an inactivity timer. The previous `after timeout_ms` reset on every
  # output chunk, so a child looping while printing never tripped it. `:infinity`
  # is preserved (no deadline) for callers that opt out of a timeout.
  defp collect(port, state, timeout_ms) do
    collect(port, state, :deadline, deadline_from(timeout_ms))
  end

  defp collect(port, state, :deadline, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, append_output(state, data), :deadline, deadline)

      {^port, {:exit_status, code}} ->
        {:exit, code, state.output}
    after
      remaining(deadline) ->
        kill_port(port)
        {:timeout, state.output}
    end
  end

  defp deadline_from(:infinity), do: :infinity
  defp deadline_from(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp append_output(%{max_bytes: max_bytes, log_io: log_io} = state, data) do
    write_log(log_io, data)
    bytes = state.bytes + byte_size(data)
    output = state.output <> data

    %{state | bytes: bytes, output: trim_output(output, max_bytes)}
  end

  defp open_log(nil), do: nil

  defp open_log(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} -> io
      {:error, _reason} -> nil
    end
  end

  defp write_log(nil, _data), do: :ok

  defp write_log(io, data) do
    _ = :file.write(io, data)
    :ok
  end

  defp close_log(nil), do: :ok

  defp close_log(io) do
    _ = File.close(io)
    :ok
  end

  defp trim_output(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp trim_output(output, max_bytes) do
    marker = "\n...[mutalisk output truncated; retaining last #{max_bytes} bytes]...\n"
    keep_bytes = max(max_bytes - byte_size(marker), 0)
    # Advance to a valid UTF-8 boundary so JSON encoding never sees a broken grapheme.
    marker <> utf8_align(binary_part(output, byte_size(output), -keep_bytes))
  end

  # Drop at most 3 leading UTF-8 continuation bytes (0x80–0xBF) that result from
  # slicing at an arbitrary byte offset inside a multi-byte codepoint.
  defp utf8_align(<<b, rest::binary>>) when b >= 0x80 and b <= 0xBF, do: utf8_align(rest)
  defp utf8_align(binary), do: binary

  # Tree-kill (TERM then KILL across the descendant tree) lives in
  # Mut.ProcessTree, shared with Mut.Worker so the two paths can't drift.
  defp kill_port(port), do: Mut.ProcessTree.kill_port(port)
end
