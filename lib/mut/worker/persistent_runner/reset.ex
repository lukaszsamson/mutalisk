defmodule Mut.Worker.PersistentRunner.Reset do
  @dialyzer {:no_opaque,
             [
               reset_ets_tables: 1,
               reset_registered: 1,
               reset_persistent_terms: 2
             ]}

  @moduledoc """
  Per-leak-vector snapshot/reset helpers for the persistent worker.

  Used by `Mut.Worker.PersistentRunner` between mutant runs.
  Extracted so the leak-vector logic can be unit-tested directly,
  without spawning a worker BEAM.

  ## Vectors covered

  Each function captures a baseline snapshot at boot and resets the
  matching state to that baseline after each `ExUnit.run/0`:

    * `capture_app_env/0` / `reset_app_env/1`
    * `capture_ets_tables/0` / `reset_ets_tables/1`
    * `capture_registered/0` / `reset_registered/1`
    * `capture_persistent_terms/0` / `reset_persistent_terms/2`
      (the second argument lists keys to preserve unconditionally,
      e.g. mutalisk's `{Mut.Runtime, :active_mutant}`).
    * `clear_on_exit_handler/0` clears ExUnit's
      `OnExitHandler` ETS so callbacks registered by a leaky test
      do not fire under the next mutant.
  """

  ## --- Application env ----------------------------------------------------

  # OTP system apps whose env is owned by the runtime; we never touch
  # them. Mutating their env can crash supervisors mid-run.
  @system_apps ~w(kernel stdlib elixir compiler asn1 crypto ssl public_key
                  sasl runtime_tools mix iex hex logger inets ex_unit
                  syntax_tools tools)a

  @spec capture_app_env() :: %{atom() => keyword()}
  def capture_app_env do
    Application.loaded_applications()
    |> Enum.reject(fn {app, _desc, _vsn} -> app in @system_apps end)
    |> Enum.map(fn {app, _desc, _vsn} -> {app, Application.get_all_env(app)} end)
    |> Map.new()
  end

  @spec reset_app_env(%{atom() => keyword()}) :: :ok
  def reset_app_env(baseline) when is_map(baseline) do
    Enum.each(baseline, &reset_app_env_for/1)
    :ok
  end

  defp reset_app_env_for({app, baseline_env}) do
    current = app |> Application.get_all_env() |> Map.new()
    baseline_map = Map.new(baseline_env)

    Enum.each(baseline_map, &restore_baseline_value(app, current, &1))

    for key <- Map.keys(current), not Map.has_key?(baseline_map, key) do
      Application.delete_env(app, key, persistent: true)
    end
  end

  defp restore_baseline_value(app, current, {key, value}) do
    if Map.get(current, key) != value do
      Application.put_env(app, key, value, persistent: true)
    end
  end

  ## --- ETS tables ---------------------------------------------------------

  @spec capture_ets_tables() :: MapSet.t()
  def capture_ets_tables do
    :ets.all() |> MapSet.new()
  end

  @spec reset_ets_tables(MapSet.t()) :: :ok
  def reset_ets_tables(%MapSet{} = baseline) do
    current = :ets.all() |> MapSet.new()

    current
    |> MapSet.difference(baseline)
    |> Enum.each(fn table ->
      try do
        :ets.delete(table)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  ## --- Registered processes ----------------------------------------------

  @spec capture_registered() :: MapSet.t()
  def capture_registered do
    Process.registered() |> MapSet.new()
  end

  @spec reset_registered(MapSet.t()) :: :ok
  def reset_registered(%MapSet{} = baseline) do
    current = Process.registered() |> MapSet.new()

    current
    |> MapSet.difference(baseline)
    |> Enum.each(&kill_registered/1)

    :ok
  end

  defp kill_registered(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid when is_pid(pid) -> safe_exit(pid)
    end
  end

  defp safe_exit(pid) do
    if Process.alive?(pid) do
      try do
        Process.exit(pid, :shutdown)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  ## --- :persistent_term ---------------------------------------------------

  # `MapSet.t/0` is opaque; under Elixir 1.19+ dialyzer the success typing
  # reveals the internal struct shape, so an explicit `@spec` would trigger
  # `contract_with_opaque`. We omit the spec here and rely on the public
  # contract being preserved by callers using `MapSet` operations only.
  @dialyzer {:no_opaque, capture_persistent_terms: 0}
  def capture_persistent_terms do
    :persistent_term.get() |> Enum.map(fn {k, _v} -> k end) |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  @spec reset_persistent_terms(MapSet.t(), [term()]) :: :ok
  def reset_persistent_terms(%MapSet{} = baseline, preserve \\ []) when is_list(preserve) do
    preserve_set = MapSet.new(preserve)

    current_keys =
      :persistent_term.get()
      |> Enum.map(fn {k, _v} -> k end)
      |> MapSet.new()

    current_keys
    |> MapSet.difference(baseline)
    |> Enum.each(fn key ->
      unless MapSet.member?(preserve_set, key) do
        try do
          :persistent_term.erase(key)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  ## --- ExUnit OnExitHandler ----------------------------------------------

  @spec clear_on_exit_handler() :: :ok
  def clear_on_exit_handler do
    case :ets.whereis(ExUnit.OnExitHandler) do
      :undefined ->
        :ok

      _ref ->
        try do
          :ets.delete_all_objects(ExUnit.OnExitHandler)
        catch
          _, _ -> :ok
        end
    end

    :ok
  end
end
