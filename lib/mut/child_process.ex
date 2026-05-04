defmodule Mut.ChildProcess do
  @moduledoc "Runs child processes with bounded output retention."

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
        port = open_port(path, args, opts)
        collect(port, init_state(opts), Keyword.get(opts, :timeout_ms, :infinity))
    end
  end

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
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp init_state(opts) do
    %{
      output: "",
      bytes: 0,
      max_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    }
  end

  defp collect(port, state, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect(port, append_output(state, data), timeout_ms)

      {^port, {:exit_status, code}} ->
        {:exit, code, state.output}
    after
      timeout_ms ->
        kill_port(port)
        {:timeout, state.output}
    end
  end

  defp append_output(%{max_bytes: max_bytes} = state, data) do
    bytes = state.bytes + byte_size(data)
    output = state.output <> data

    %{state | bytes: bytes, output: trim_output(output, max_bytes)}
  end

  defp trim_output(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp trim_output(output, max_bytes) do
    marker = "\n...[mutalisk output truncated; retaining last #{max_bytes} bytes]...\n"
    keep_bytes = max(max_bytes - byte_size(marker), 0)
    marker <> binary_part(output, byte_size(output), -keep_bytes)
  end

  defp kill_port(port) do
    os_pid = Port.info(port, :os_pid)
    Port.close(port)

    case os_pid do
      {:os_pid, pid} when is_integer(pid) -> kill_process_tree(pid)
      _unknown -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp kill_process_tree(pid) do
    descendants = descendant_pids(pid)

    Enum.each(descendants, &kill_pid(&1, "-TERM"))
    kill_pid(pid, "-TERM")
    Process.sleep(100)
    Enum.each(descendants, &kill_pid(&1, "-KILL"))
    kill_pid(pid, "-KILL")
    :ok
  end

  defp descendant_pids(pid) do
    pid
    |> child_pids()
    |> Enum.flat_map(fn child_pid -> [child_pid | descendant_pids(child_pid)] end)
  end

  defp child_pids(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_pid/1)

      _no_children ->
        []
    end
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {child_pid, ""} -> [child_pid]
      _invalid -> []
    end
  end

  defp kill_pid(pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
  end
end
