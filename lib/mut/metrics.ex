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
      :by_status,
      :by_engine_status,
      :fallback_count_pct,
      :wall_clock_ms,
      :rollback_per_file,
      :invalid_by_mutator,
      :skipped_by_reason,
      :test_selection_fanout,
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
            ledger: [ledger_entry()]
          }
  end

  @type state :: %{
          by_status: map(),
          by_engine_status: map(),
          wall_clock_ms: map(),
          rollback_per_file: map(),
          invalid_by_mutator: map(),
          skipped_by_reason: map(),
          test_selection_fanout: map(),
          ledger: [Snapshot.ledger_entry()]
        }

  @spec start_link(opts :: keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

  @spec record_mutant(pid :: GenServer.server(), mutant :: Mutant.t(), result :: Result.t()) ::
          :ok
  def record_mutant(pid, %Mutant{} = mutant, %Result{} = result) do
    GenServer.cast(pid, {:record_mutant, mutant, result})
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

  @spec snapshot(pid :: GenServer.server()) :: Snapshot.t()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       by_status: %{},
       by_engine_status: %{},
       wall_clock_ms: %{schema: 0, fallback: 0, total: 0},
       rollback_per_file: %{},
       invalid_by_mutator: %{},
       skipped_by_reason: %{},
       test_selection_fanout: %{},
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

    %Snapshot{
      total: length(ledger),
      score: score(killed, survived),
      by_status: by_status,
      by_engine_status: state.by_engine_status,
      fallback_count_pct: fallback_count_pct(state.by_engine_status),
      wall_clock_ms: state.wall_clock_ms,
      rollback_per_file: state.rollback_per_file,
      invalid_by_mutator: state.invalid_by_mutator,
      skipped_by_reason: state.skipped_by_reason,
      test_selection_fanout: state.test_selection_fanout,
      ledger: ledger
    }
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
end
