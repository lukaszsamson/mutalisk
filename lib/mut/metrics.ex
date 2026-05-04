defmodule Mut.Metrics do
  @moduledoc "Accumulates mutation run metrics for reporters."

  use GenServer

  alias Mut.Mutant
  alias Mut.Worker.Result

  defmodule Snapshot do
    @moduledoc "Immutable mutation run metrics snapshot."

    defstruct [
      :total,
      :score,
      :planned_total,
      :by_status,
      :by_engine_status,
      :fallback_count_pct,
      :wall_clock_ms,
      :rollback_per_file,
      :invalid_by_mutator,
      :skipped_by_reason,
      :test_selection_fanout,
      :phase_timings,
      :ledger
    ]

    @type ledger_entry :: %{
            optional(:id) => non_neg_integer(),
            optional(:stable_id) => String.t(),
            optional(:engine) => Mutant.engine(),
            optional(:status) => Mutant.status(),
            optional(:file) => Path.t(),
            optional(:line) => pos_integer() | nil,
            optional(:column) => pos_integer() | nil,
            optional(:mutator) => module(),
            optional(:mutator_name) => String.t(),
            optional(:mutation_kind) => atom() | nil,
            optional(:description) => String.t(),
            optional(:duration_ms) => non_neg_integer() | nil,
            optional(:killing_test) => String.t() | nil,
            optional(:covering_tests) => [String.t()] | nil,
            optional(:skip_reason) => atom() | nil,
            optional(:compile_error) => term(),
            optional(:mutant) => Mutant.t(),
            optional(:result) => Result.t() | nil
          }

    @type t :: %__MODULE__{
            total: non_neg_integer(),
            score: float(),
            planned_total: non_neg_integer() | nil,
            by_status: %{Mutant.status() => non_neg_integer()},
            by_engine_status: %{{Mutant.engine(), Mutant.status()} => non_neg_integer()},
            fallback_count_pct: float(),
            wall_clock_ms: %{
              schema: non_neg_integer(),
              fallback: non_neg_integer(),
              total: non_neg_integer()
            },
            rollback_per_file: %{Path.t() => pos_integer()},
            invalid_by_mutator: %{module() => pos_integer()},
            skipped_by_reason: %{atom() => pos_integer()},
            test_selection_fanout: %{String.t() => non_neg_integer()},
            phase_timings: %{atom() => non_neg_integer()},
            ledger: [ledger_entry()]
          }
  end

  @phases [
    :oracle_build,
    :baseline_tests,
    :plan_generation,
    :coverage_collection,
    :schema_build,
    :schema_workers,
    :fallback_workers,
    :report_writing
  ]

  @type state :: %{
          planned_total: non_neg_integer() | nil,
          by_status: map(),
          by_engine_status: map(),
          wall_clock_ms: map(),
          rollback_per_file: map(),
          invalid_by_mutator: map(),
          skipped_by_reason: map(),
          test_selection_fanout: map(),
          phase_starts: map(),
          phase_timings: map(),
          phase_warnings: [term()],
          started_ms: integer(),
          ledger: [Snapshot.ledger_entry()]
        }

  @spec start_link(opts :: keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

  @spec record_mutant(pid :: GenServer.server(), mutant :: Mutant.t(), result :: Result.t()) ::
          :ok
  def record_mutant(pid, %Mutant{} = mutant, %Result{} = result) do
    GenServer.cast(pid, {:record_mutant, mutant, result})
  end

  @spec set_planned_total(pid :: GenServer.server(), non_neg_integer) :: :ok
  def set_planned_total(pid, total) when is_integer(total) and total >= 0 do
    GenServer.cast(pid, {:set_planned_total, total})
  end

  @spec record_skipped(pid :: GenServer.server(), skipped_entry :: map()) :: :ok
  def record_skipped(pid, skipped_entry) when is_map(skipped_entry) do
    GenServer.cast(pid, {:record_skipped, skipped_entry})
  end

  @spec record_invalid(pid :: GenServer.server(), mutant :: Mutant.t()) :: :ok
  def record_invalid(pid, %Mutant{} = mutant) do
    GenServer.cast(pid, {:record_invalid, mutant})
  end

  @spec record_compile_rollback(
          pid :: GenServer.server(),
          file :: Path.t(),
          removed_count :: pos_integer()
        ) :: :ok
  def record_compile_rollback(pid, file, removed_count)
      when is_binary(file) and is_integer(removed_count) and removed_count > 0 do
    GenServer.cast(pid, {:record_compile_rollback, file, removed_count})
  end

  @spec start_phase(GenServer.server(), phase_name :: atom) :: :ok
  def start_phase(pid, phase) when is_atom(phase) do
    GenServer.cast(pid, {:start_phase, phase, monotonic_ms()})
  end

  @spec end_phase(GenServer.server(), phase_name :: atom) :: :ok
  def end_phase(pid, phase) when is_atom(phase) do
    GenServer.cast(pid, {:end_phase, phase, monotonic_ms()})
  end

  @spec with_phase(GenServer.server(), phase_name :: atom, fun :: (-> any)) :: any
  def with_phase(pid, phase, fun) when is_function(fun, 0) and is_atom(phase) do
    start_phase(pid, phase)

    try do
      fun.()
    after
      end_phase(pid, phase)
    end
  end

  @spec snapshot(pid :: GenServer.server()) :: Snapshot.t()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       planned_total: nil,
       by_status: %{},
       by_engine_status: %{},
       wall_clock_ms: %{schema: 0, fallback: 0, total: 0},
       rollback_per_file: %{},
       invalid_by_mutator: %{},
       skipped_by_reason: %{},
       test_selection_fanout: %{},
       phase_starts: %{},
       phase_timings: %{},
       phase_warnings: [],
       started_ms: monotonic_ms(),
       ledger: []
     }}
  end

  @impl GenServer
  def handle_cast({:record_mutant, mutant, result}, state) do
    status = result.status
    duration_ms = result.duration_ms || 0
    entry = ledger_entry(mutant, result, status)

    {:noreply,
     state
     |> increment_status(status)
     |> increment_engine_status(mutant.engine, status)
     |> add_wall_clock(mutant.engine, duration_ms)
     |> put_fanout(mutant)
     |> prepend_ledger(entry)}
  end

  def handle_cast({:set_planned_total, total}, state) do
    {:noreply, %{state | planned_total: total}}
  end

  def handle_cast({:record_skipped, skipped_entry}, state) do
    reason = Map.get(skipped_entry, :reason) || Map.get(skipped_entry, "reason") || :unknown
    entry = Map.merge(skipped_entry, %{status: :skipped, skip_reason: reason})

    {:noreply,
     state
     |> increment_status(:skipped)
     |> increment_map(:skipped_by_reason, reason, 1)
     |> prepend_ledger(entry)}
  end

  def handle_cast({:record_invalid, mutant}, state) do
    entry = ledger_entry(mutant, nil, :invalid)

    {:noreply,
     state
     |> increment_status(:invalid)
     |> increment_engine_status(mutant.engine, :invalid)
     |> increment_map(:invalid_by_mutator, mutant.mutator, 1)
     |> put_fanout(mutant)
     |> prepend_ledger(entry)}
  end

  def handle_cast({:record_compile_rollback, file, removed_count}, state) do
    {:noreply, increment_map(state, :rollback_per_file, file, removed_count)}
  end

  def handle_cast({:start_phase, phase, started_ms}, state) do
    warning =
      if Map.has_key?(state.phase_starts, phase), do: {:phase_restarted, phase}, else: nil

    {:noreply,
     state
     |> put_in([:phase_starts, phase], started_ms)
     |> maybe_prepend_phase_warning(warning)}
  end

  def handle_cast({:end_phase, phase, ended_ms}, state) do
    case Map.fetch(state.phase_starts, phase) do
      {:ok, started_ms} ->
        duration_ms = max(ended_ms - started_ms, 0)

        {:noreply,
         state
         |> put_in([:phase_timings, phase], duration_ms)
         |> update_in([:phase_starts], &Map.delete(&1, phase))}

      :error ->
        {:noreply, put_in(state, [:phase_timings, phase], 0)}
    end
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  defp ledger_entry(%Mutant{} = mutant, result, status) do
    duration_ms = if result, do: result.duration_ms, else: mutant.duration_ms
    killing_test = if result, do: result.killing_test, else: mutant.killing_test

    %{
      id: mutant.id,
      stable_id: mutant.stable_id,
      engine: mutant.engine,
      status: status,
      file: mutant.file,
      line: mutant.line,
      column: mutant.column,
      span: mutant.span,
      mutator: mutant.mutator,
      mutator_name: mutant.mutator_name,
      mutation_kind: mutant.mutation_kind,
      description: mutant.description,
      duration_ms: duration_ms,
      killing_test: killing_test,
      covering_tests: mutant.covering_tests,
      skip_reason: mutant.skip_reason,
      compile_error: mutant.compile_error,
      mutant: mutant,
      result: result
    }
  end

  defp build_snapshot(state) do
    ledger = Enum.reverse(state.ledger)
    by_status = state.by_status
    killed = Map.get(by_status, :killed, 0)
    survived = Map.get(by_status, :survived, 0)

    executed_ledger = Enum.reject(ledger, &(&1.status in [:skipped, :invalid]))

    %Snapshot{
      total: length(executed_ledger),
      score: score(killed, survived),
      planned_total: state.planned_total,
      by_status: by_status,
      by_engine_status: state.by_engine_status,
      fallback_count_pct: fallback_count_pct(state.by_engine_status),
      wall_clock_ms: state.wall_clock_ms,
      rollback_per_file: state.rollback_per_file,
      invalid_by_mutator: state.invalid_by_mutator,
      skipped_by_reason: state.skipped_by_reason,
      test_selection_fanout: state.test_selection_fanout,
      phase_timings: phase_timings(state),
      ledger: ledger
    }
  end

  defp phase_timings(state) do
    base =
      Map.new(@phases, fn phase ->
        {:"#{phase}_ms", Map.get(state.phase_timings, phase, 0)}
      end)

    Map.put(base, :total_ms, max(monotonic_ms() - state.started_ms, 0))
  end

  defp score(0, 0), do: 100.0
  defp score(killed, survived), do: killed / (killed + survived) * 100.0

  defp fallback_count_pct(by_engine_status) do
    schema = engine_count(by_engine_status, :schema)
    fallback = engine_count(by_engine_status, :fallback)

    case schema + fallback do
      0 -> 0.0
      total -> fallback / total * 100.0
    end
  end

  defp engine_count(by_engine_status, engine) do
    by_engine_status
    |> Enum.filter(fn {{entry_engine, _status}, _count} -> entry_engine == engine end)
    |> Enum.reduce(0, fn {_key, count}, total -> total + count end)
  end

  defp increment_status(state, status), do: increment_map(state, :by_status, status, 1)

  defp increment_engine_status(state, engine, status) do
    increment_map(state, :by_engine_status, {engine, status}, 1)
  end

  defp add_wall_clock(state, engine, duration_ms) when engine in [:schema, :fallback] do
    state
    |> update_in([:wall_clock_ms, engine], &((&1 || 0) + duration_ms))
    |> update_in([:wall_clock_ms, :total], &((&1 || 0) + duration_ms))
  end

  defp put_fanout(state, %Mutant{stable_id: stable_id, covering_tests: covering_tests}) do
    fanout = length(covering_tests || [])
    put_in(state, [:test_selection_fanout, stable_id], fanout)
  end

  defp prepend_ledger(state, entry), do: update_in(state.ledger, &[entry | &1])

  defp increment_map(state, field, key, amount) do
    update_in(state[field], &Map.update(&1, key, amount, fn count -> count + amount end))
  end

  defp maybe_prepend_phase_warning(state, nil), do: state

  defp maybe_prepend_phase_warning(state, warning),
    do: update_in(state.phase_warnings, &[warning | &1])

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
end
