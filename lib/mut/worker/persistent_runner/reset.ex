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

  ## --- Mox.Server (M28) --------------------------------------------------

  # Mox v1.x stores per-test expectations / allowances / stubs in a
  # `NimbleOwnership` GenServer registered as `Mox.Server`, supervised
  # by `Mox.Supervisor` (one_for_one, child_id `Mox`). Between mutants
  # the persistent worker leaves this state in place — mutant N's
  # expectations leak into mutant N+1, producing both false-negative
  # `Killed → Survived` flips (a previous mutant's stub answers in
  # place of the current mutant's failing path) and false-positive
  # `Survived → Killed` flips (cumulative `expect/4` calls overflow
  # exactly-N invocation counts). M25 mox v1.2.0 measured 13.2%
  # drift; M27's bucketer attributed 3 of 5 drifting mutants to this
  # class.
  #
  # Mocks themselves are compiled modules created by `Mox.defmock/2`
  # — they do not live in the NimbleOwnership process state. So
  # tearing the server down and letting the supervisor restart it
  # gives us a clean slate without losing test-load setup.
  #
  # Strategy: ask the supervisor to terminate + restart the `Mox`
  # child. Tolerate the case where Mox isn't loaded (no-op) or the
  # supervisor was never started (no-op). Never raises; never blocks
  # the mutant pipeline.
  @spec reset_mox() :: :ok
  def reset_mox do
    cond do
      not mox_loaded?() ->
        :ok

      Process.whereis(Mox.Supervisor) == nil ->
        :ok

      true ->
        restart_mox_child()
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mox_loaded? do
    Code.ensure_loaded?(Mox.Supervisor)
  end

  defp restart_mox_child do
    sup = Mox.Supervisor

    # `terminate_child/2` returns `:ok` regardless of whether the
    # child was actually running. `restart_child/2` then either
    # spawns a fresh worker or returns `{:error, :running}` if the
    # supervisor already restarted on its own; both are fine.
    _ = Supervisor.terminate_child(sup, Mox)
    _ = Supervisor.restart_child(sup, Mox)
    wait_for_mox_server(50)
    :ok
  end

  # The supervisor's restart_child is synchronous through to
  # `start_child`, but NimbleOwnership performs further setup in its
  # `init/1` callback (creates ETS tables, monitors). The tests that
  # follow may call into Mox.Server immediately and hit a race where
  # the named process exists but its state is incomplete. Spin until
  # `Process.whereis/1` returns a live pid; bounded by attempt count
  # so we never block the mutant pipeline on a failed start.
  defp wait_for_mox_server(0), do: :ok

  defp wait_for_mox_server(attempts) do
    case Process.whereis(Mox.Server) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: retry_wait(attempts)

      _ ->
        retry_wait(attempts)
    end
  end

  defp retry_wait(attempts) do
    Process.sleep(1)
    wait_for_mox_server(attempts - 1)
  end

  ## --- Ecto compile/query state (M30) ------------------------------------

  # Ecto's `Ecto.Query.Planner` keeps a per-repo ETS-backed query
  # cache (`:ets.new(Repo.Module, [:set, :public, read_concurrency])`)
  # populated lazily during test execution. `Ecto.Repo.Registry`
  # tracks running repos in a named ETS table. Both are created at
  # repo startup and live for the BEAM's lifetime — they survive
  # mutant boundaries, so mutant N's plans are visible to mutant
  # N+1's tests, producing both `Survived → Killed` flips
  # (mutant's bad plan got cached, next mutant misses the cache and
  # sees the previous fault) and `Killed → Survived` flips (mutant's
  # mutation never re-evaluates because the cached plan still
  # answers).
  #
  # Strategy: find ETS tables whose registered owner is an Ecto-named
  # process and call `:ets.delete_all_objects/1` to wipe entries
  # without destroying the table (destroying it would break the next
  # mutant's queries; we only need fresh entries). Skip
  # `Ecto.Repo.Registry` itself (clearing the registry would
  # invalidate live repo references).
  #
  # No-op when `:ecto` is not loaded. Tolerates errors silently.
  @spec reset_ecto() :: :ok
  def reset_ecto do
    if ecto_loaded?() do
      do_reset_ecto()
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ecto_loaded? do
    Code.ensure_loaded?(Ecto.Query.Planner) and
      :ets.whereis(Ecto.Repo.Registry) != :undefined
  end

  @ecto_registry_table Ecto.Repo.Registry

  defp do_reset_ecto do
    :ets.all()
    |> Enum.each(&maybe_clear_ecto_table/1)

    :ok
  end

  defp maybe_clear_ecto_table(table) do
    cond do
      table == @ecto_registry_table -> :ok
      ecto_owned_table?(table) -> safe_delete_all_objects(table)
      true -> :ok
    end
  end

  defp ecto_owned_table?(table) do
    case :ets.info(table, :owner) do
      :undefined ->
        false

      pid when is_pid(pid) ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) ->
            name |> Atom.to_string() |> String.starts_with?("Elixir.Ecto.")

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp safe_delete_all_objects(table) do
    try do
      :ets.delete_all_objects(table)
    catch
      _, _ -> :ok
    end

    :ok
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
