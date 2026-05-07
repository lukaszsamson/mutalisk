defmodule Mut.Worker.PersistentRunner.Diag do
  @moduledoc """
  Diagnostic timing + memory helpers for the persistent worker.

  Captures per-phase timings as `:erlang.monotonic_time(:microsecond)`
  diffs and serialises them to JSON for the host to parse. The host
  side accumulates them into `Mut.Metrics.Snapshot.persistent`.

  Two protocol lines are emitted on stdout, both in addition to the
  existing `MUT_READY` / `MUT_RESULT` markers:

      MUT_BOOT_METRICS <json>   (once, immediately before MUT_READY)
      MUT_RUN_METRICS  <json>   (once per RUN, immediately before
                                 MUT_RESULT)

  The host's wait_for_ready / wait_for_result loops capture and parse
  these lines without changing the existing protocol.

  Format is intentionally a flat JSON object — no nested timing trees,
  no per-app breakdown — so parsing on the host side is cheap and the
  on-the-wire payload stays small.

  Compile-time gate: setting the module-attr `@diag false` (or env
  `MUT_PERSISTENT_DIAG=0` at the runner's launch time) disables the
  per-mutant overhead. The boot block always emits because boot
  happens once.
  """

  @boot_marker "MUT_BOOT_METRICS"
  @run_marker "MUT_RUN_METRICS"

  @type us :: non_neg_integer()

  @doc """
  Returns `true` when per-mutant diagnostics should be emitted.
  Disable via `MUT_PERSISTENT_DIAG=0` to measure baseline overhead
  without instrumentation in the hot path.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("MUT_PERSISTENT_DIAG") do
      "0" -> false
      _ -> true
    end
  end

  @doc "Wall-clock microseconds since `t0` (a monotonic timestamp)."
  @spec elapsed_us(integer()) :: us()
  def elapsed_us(t0) when is_integer(t0) do
    max(:erlang.monotonic_time(:microsecond) - t0, 0)
  end

  @doc "Returns `:erlang.monotonic_time(:microsecond)`."
  @spec now_us() :: integer()
  def now_us, do: :erlang.monotonic_time(:microsecond)

  @doc """
  Times a 0-arity fun and returns `{result, microseconds}`.
  """
  @spec time(fun :: (-> any())) :: {any(), us()}
  def time(fun) when is_function(fun, 0) do
    t0 = now_us()
    result = fun.()
    {result, elapsed_us(t0)}
  end

  @doc """
  Captures `:erlang.memory/1` totals as `{total_bytes, processes_bytes}`.
  Cheap-ish (~10μs); call sparingly — once at boot, once per mutant.
  """
  @spec memory_snapshot() :: {non_neg_integer(), non_neg_integer()}
  def memory_snapshot do
    mem = :erlang.memory()
    {Keyword.get(mem, :total, 0), Keyword.get(mem, :processes, 0)}
  end

  @doc """
  Emits the boot-metrics protocol line. Called once at runner boot,
  immediately before `MUT_READY`.
  """
  @spec emit_boot(%{
          boot_us: us(),
          app_startup_us: us(),
          app_startup_count: non_neg_integer(),
          test_load_us: us(),
          test_load_count: non_neg_integer(),
          memory_total: non_neg_integer(),
          memory_processes: non_neg_integer()
        }) :: :ok
  def emit_boot(metrics) when is_map(metrics) do
    emit_line(@boot_marker, metrics)
  end

  @doc """
  Emits the run-metrics protocol line. Called once per RUN, immediately
  before `MUT_RESULT`.
  """
  @spec emit_run(%{
          run_us: us(),
          filter_us: us(),
          reset_app_env_us: us(),
          reset_ets_us: us(),
          reset_processes_us: us(),
          reset_persistent_term_us: us(),
          reset_on_exit_us: us(),
          memory_total: non_neg_integer(),
          memory_processes: non_neg_integer()
        }) :: :ok
  def emit_run(metrics) when is_map(metrics) do
    emit_line(@run_marker, metrics)
  end

  @doc "The boot-metrics line marker used by the host parser."
  @spec boot_marker() :: String.t()
  def boot_marker, do: @boot_marker

  @doc "The run-metrics line marker used by the host parser."
  @spec run_marker() :: String.t()
  def run_marker, do: @run_marker

  @doc """
  Parses a `MUT_BOOT_METRICS <json>` or `MUT_RUN_METRICS <json>` line.
  Returns `{:ok, atom_keyed_map}` or `:error`.
  """
  @spec parse_line(binary()) :: {:ok, atom(), map()} | :error
  def parse_line(@boot_marker <> " " <> rest), do: decode(rest, :boot)
  def parse_line(@run_marker <> " " <> rest), do: decode(rest, :run)
  def parse_line(_), do: :error

  defp decode(rest, kind) do
    case Jason.decode(String.trim(rest)) do
      {:ok, map} when is_map(map) ->
        {:ok, kind, atomize_keys(map)}

      _ ->
        :error
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> map
  end

  defp emit_line(marker, metrics) do
    case Jason.encode(metrics) do
      {:ok, payload} -> IO.puts(marker <> " " <> payload)
      _ -> :ok
    end
  end
end
