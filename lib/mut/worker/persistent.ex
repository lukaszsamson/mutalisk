defmodule Mut.Worker.Persistent do
  @moduledoc """
  Host-side controller for a persistent ExUnit worker BEAM.

  See `V17_PERSISTENT_WORKER.md` and `Mut.Worker.PersistentRunner`.
  M19 step 1 implements the schema-only path: spawn one BEAM per
  sandbox, hold ExUnit + the user's test files in memory, flip
  `:persistent_term` per mutant. Subsequent steps add reset hooks
  (step 2), file-level filtering (step 3), parallel pool integration
  (step 4), in-process fallback recompile (step 5), and crash
  recovery (step 6).

  ## Lifecycle

      {:ok, server} = Mut.Worker.Persistent.start_link(sandbox)
      result = Mut.Worker.Persistent.run_schema(server, mutant_id, [])
      :ok = Mut.Worker.Persistent.stop(server)

  ## Notes for step 1

  - Only schema mutants run here; fallback still routes to
    `Mut.Worker.run_fallback/4` (the mix-spawn path).
  - The `test_files` argument is currently ignored (step 3 wires the
    `only_test_ids` filter); the worker runs every loaded test
    module on each `run_schema` call. This matches v1.5/v1.6
    selection on demo_app where the per-mutant set is small enough
    that running everything is still cheap.
  - `--worker-type persistent` is undocumented in step 1; the public
    flag promotion is step 7.
  """

  use GenServer

  alias Mut.Sandbox
  alias Mut.Worker.Formatter
  alias Mut.Worker.Result

  @ready_marker "MUT_READY"
  @result_marker "MUT_RESULT"
  @default_boot_timeout_ms 30_000
  @default_run_timeout_ms 60_000

  @type server :: GenServer.server()

  @spec start_link(Sandbox.t(), keyword) :: GenServer.on_start()
  def start_link(%Sandbox{} = sandbox, opts \\ []) do
    # Intentionally `GenServer.start/3` (not `start_link`). When the
    # persistent worker BEAM crashes, the GenServer stops with
    # :worker_crashed. We want that crash to surface only via
    # `Persistent.run_schema/4`'s GenServer.call exit (which the host
    # catches and routes to mix) — NOT to propagate as a linked-exit
    # signal that takes down the host's Task.async_stream worker.
    GenServer.start(__MODULE__, {sandbox, opts})
  end

  @spec run_schema(server, non_neg_integer(), [Path.t()], keyword) :: Result.t() | :filter_miss
  def run_schema(server, mutant_id, test_files, opts \\ [])
      when is_integer(mutant_id) and mutant_id >= 0 and is_list(test_files) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)
    GenServer.call(server, {:run_schema, mutant_id, test_files, timeout_ms}, timeout_ms + 5_000)
  end

  @spec stop(server, timeout()) :: :ok
  def stop(server, timeout \\ 5_000) do
    GenServer.stop(server, :normal, timeout)
  end

  ## GenServer

  @impl GenServer
  def init({%Sandbox{} = sandbox, opts}) do
    Process.flag(:trap_exit, true)
    boot_timeout = Keyword.get(opts, :boot_timeout_ms, @default_boot_timeout_ms)

    case open_port(sandbox, opts) do
      {:ok, port, leftover} ->
        case wait_for_ready(port, leftover, boot_timeout) do
          {:ok, leftover} ->
            {:ok, %{port: port, sandbox: sandbox, leftover: leftover}}

          {:error, reason} ->
            kill_port(port)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:run_schema, mutant_id, test_files, timeout_ms}, _from, state) do
    started = System.monotonic_time(:millisecond)
    files_blob = encode_files(test_files, state.sandbox)
    Port.command(state.port, "RUN #{mutant_id}#{files_blob}\n")

    case wait_for_result(state.port, state.leftover, timeout_ms) do
      {:ok, %Result{status: :filter_miss}, _leftover} ->
        # Filter miss is recoverable: the worker BEAM is still
        # healthy, but the host needs to rerun this mutant via mix
        # because the persistent runner could not resolve the
        # selected files to any loaded test ids. Reply with
        # :filter_miss; the caller treats it the same as a crash
        # exit and re-routes via mix without tearing the BEAM down.
        {:reply, :filter_miss, %{state | leftover: ""}}

      {:ok, result, leftover} ->
        duration_ms = System.monotonic_time(:millisecond) - started
        {:reply, %{result | duration_ms: duration_ms}, %{state | leftover: leftover}}

      {:error, :timeout, leftover} ->
        _raw_output = leftover
        kill_port(state.port)

        {:stop, :worker_crashed, %{state | leftover: ""}}

      {:error, :crashed, leftover} ->
        _raw_output = leftover

        {:stop, :worker_crashed, %{state | leftover: ""}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port) != nil do
      _ = Port.command(port, "STOP\n")
      kill_port(port)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp open_port(sandbox, opts) do
    elixir = Keyword.get(opts, :elixir_path) || System.find_executable("elixir")

    if elixir == nil do
      {:error, :elixir_not_found}
    else
      args = elixir_args(sandbox, opts)
      env = port_env(opts)

      port =
        Port.open({:spawn_executable, elixir}, [
          {:args, args},
          {:cd, sandbox.path},
          {:env, env},
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 65_536}
        ])

      {:ok, port, ""}
    end
  end

  defp elixir_args(sandbox, opts) do
    pa_flags =
      sandbox.path
      |> Path.join("_build/mut_schema/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn ebin ->
        relative = Path.relative_to(ebin, sandbox.path)
        ["-pa", relative]
      end)

    test_files = discover_test_files(sandbox, opts)
    test_helper = test_helper_path(sandbox, opts)

    eval =
      "Mut.Worker.PersistentRunner.run(#{inspect(test_files)}, " <>
        inspect_helper_opt(test_helper) <> ")"

    # No `--no-halt`: when the runner's loop exits (STOP command or
    # stdin EOF), the BEAM should terminate naturally. With --no-halt
    # the worker BEAM survives port closure forever and accumulates as
    # an orphan, which breaks subsequent test runs that read from
    # stale processes.
    pa_flags ++ ["--eval", eval]
  end

  defp discover_test_files(sandbox, opts) do
    case Keyword.get(opts, :test_files) do
      nil ->
        sandbox.path
        |> Path.join("test/**/*_test.exs")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, sandbox.path))
        |> Enum.sort()

      files when is_list(files) ->
        files
    end
  end

  defp test_helper_path(sandbox, opts) do
    case Keyword.get(opts, :test_helper) do
      nil ->
        candidate = Path.join(sandbox.path, "test/test_helper.exs")

        if File.exists?(candidate) do
          Path.relative_to(candidate, sandbox.path)
        else
          nil
        end

      path ->
        path
    end
  end

  defp inspect_helper_opt(nil), do: "[]"
  defp inspect_helper_opt(path), do: "[test_helper: #{inspect(path)}]"

  defp port_env(opts) do
    base = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "persistent"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())},
      {"MUT_ACTIVE", "0"}
    ]

    extra = Keyword.get(opts, :env, [])
    merged = base ++ extra

    Enum.map(merged, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp wait_for_ready(port, leftover, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(port, leftover, deadline)
  end

  defp do_wait_for_ready(port, acc, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        if line == @ready_marker do
          {:ok, ""}
        else
          do_wait_for_ready(port, acc <> line <> "\n", deadline)
        end

      {^port, {:data, {:noeol, partial}}} ->
        do_wait_for_ready(port, acc <> partial, deadline)

      {^port, {:exit_status, code}} ->
        {:error, {:worker_exited_during_boot, code, acc}}
    after
      timeout ->
        {:error, {:worker_boot_timeout, acc}}
    end
  end

  defp wait_for_result(port, leftover, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_result(port, leftover, deadline)
  end

  defp do_wait_for_result(port, acc, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        case parse_result_line(line) do
          {:ok, status, duration_us} ->
            duration_ms = max(div(duration_us, 1000), 0)

            result =
              %Result{
                status: status,
                duration_ms: duration_ms,
                raw_output: trim_output(acc),
                killing_test: killing_test(acc)
              }

            {:ok, result, ""}

          :passthrough ->
            do_wait_for_result(port, acc <> line <> "\n", deadline)
        end

      {^port, {:data, {:noeol, partial}}} ->
        do_wait_for_result(port, acc <> partial, deadline)

      {^port, {:exit_status, _code}} ->
        {:error, :crashed, acc}
    after
      timeout ->
        {:error, :timeout, acc}
    end
  end

  defp parse_result_line(@result_marker <> " " <> rest) do
    case String.split(rest, " ", parts: 2) do
      ["killed", duration_us_str] ->
        {:ok, :killed, parse_duration(duration_us_str)}

      ["survived", duration_us_str] ->
        {:ok, :survived, parse_duration(duration_us_str)}

      ["error", _rest] ->
        {:ok, :error, 0}

      ["filter_miss", _rest] ->
        # Persistent runner could not resolve the requested test
        # files to any loaded test ids. Surface as :filter_miss so
        # the host reruns this mutant via mix.
        {:ok, :filter_miss, 0}

      _other ->
        :passthrough
    end
  end

  defp parse_result_line(_other), do: :passthrough

  defp killing_test(output) do
    case Formatter.parse_output(output) do
      %{tests: tests} ->
        tests
        |> Enum.find(&(&1["status"] == "failed"))
        |> case do
          nil -> nil
          test -> "#{test["module"]} #{test["test"]}"
        end

      _other ->
        nil
    end
  end

  defp encode_files([], _sandbox), do: ""

  defp encode_files(files, sandbox) when is_list(files) do
    " " <> Enum.map_join(files, "\t", &absolute_test_path(&1, sandbox))
  end

  defp absolute_test_path(file, sandbox) do
    case Path.type(file) do
      :absolute -> file
      _ -> Path.join(sandbox.path, file)
    end
  end

  defp parse_duration(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp trim_output(output) when byte_size(output) <= 8_192, do: output

  defp trim_output(output) do
    "...[persistent worker output truncated; retaining last 8KB]...\n" <>
      binary_part(output, byte_size(output) - 8_192, 8_192)
  end

  defp kill_port(port) when is_port(port) do
    case Port.info(port) do
      nil ->
        :ok

      _info ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end
    end
  end

  defp kill_port(_), do: :ok
end
