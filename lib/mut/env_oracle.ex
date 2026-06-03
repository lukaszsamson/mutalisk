defmodule Mut.EnvOracle do
  @moduledoc """
  In-memory index from source-span / AST-path to `Mut.EnvSnapshot`.
  Consumed by env-walker-backed mutators (e.g. `Mut.Mutator.StringLiteral`)
  as the fifth candidate source alongside dispatch / guard /
  attribute / body_literal candidates.

  M39 design: `docs/spikes/M39_env_walker.md` — section "Data
  Model" defines the wire shape, including the diagnostics
  histogram. M40 commit 3 lands the in-memory index; commit 6
  wires diagnostics through metrics.

  ## Shape

      %Mut.EnvOracle{
        by_span:       %{{file, start_byte, end_byte} => [Mut.EnvSnapshot.t()]},
        by_line:       %{{file, line, column} => Mut.EnvSnapshot.t()},
        diagnostics:   [diagnostic()],
        skip_histogram: %{atom() => non_neg_integer()}
      }

  `by_line` is the lookup the StringLiteral mutator uses (the
  walker has `line` and `column` on every snapshot in M40 commit
  2; source-span byte offsets land in M41 once the existing M23
  span computer is integrated). `by_span` is reserved for v1.15+
  when source-span mutators land.

  `skip_histogram` aggregates `Mut.EnvSnapshot.skip_reason/1`
  counts across the project's snapshots — surfaces in the
  terminal "Env walker" block and the Stryker JSON
  `mutalisk.env_walker` key (M40 commit 6).
  """

  alias Mut.EnvSnapshot

  @type diagnostic :: %{
          file: Path.t(),
          line: pos_integer() | nil,
          reason: atom(),
          detail: String.t()
        }

  defstruct by_span: %{},
            by_line: %{},
            diagnostics: [],
            skip_histogram: %{}

  @type t :: %__MODULE__{
          by_span: %{
            optional({Path.t(), non_neg_integer(), non_neg_integer()}) => [EnvSnapshot.t()]
          },
          by_line: %{optional({Path.t(), pos_integer(), pos_integer()}) => EnvSnapshot.t()},
          diagnostics: [diagnostic()],
          skip_histogram: %{optional(atom()) => non_neg_integer()}
        }

  @doc """
  Builds the oracle from a list of snapshots produced by
  `Mut.EnvWalker.collect_literal_snapshots/2` (possibly across
  multiple files).
  """
  @spec from_snapshots([EnvSnapshot.t()]) :: t()
  def from_snapshots(snapshots) when is_list(snapshots) do
    Enum.reduce(snapshots, %__MODULE__{}, &add_snapshot/2)
  end

  @doc """
  Looks up the snapshot at `{file, line, column}`. Returns
  `nil` when no exact match exists.
  """
  @spec at(t(), Path.t(), pos_integer(), pos_integer()) :: EnvSnapshot.t() | nil
  def at(%__MODULE__{} = oracle, file, line, column)
      when is_binary(file) and is_integer(line) and is_integer(column) do
    Map.get(oracle.by_line, {file, line, column})
  end

  @doc """
  Adds a single snapshot to the oracle, updating the index and
  skip-reason histogram.
  """
  @spec add_snapshot(EnvSnapshot.t(), t()) :: t()
  def add_snapshot(%EnvSnapshot{} = snap, %__MODULE__{} = oracle) do
    by_line =
      case {snap.line, snap.column} do
        {line, column} when is_integer(line) and is_integer(column) ->
          Map.put(oracle.by_line, {snap.file, line, column}, snap)

        _ ->
          oracle.by_line
      end

    histogram =
      case EnvSnapshot.skip_reason(snap) do
        nil -> oracle.skip_histogram
        reason -> Map.update(oracle.skip_histogram, reason, 1, &(&1 + 1))
      end

    %{oracle | by_line: by_line, skip_histogram: histogram}
  end

  @doc """
  Returns all snapshots eligible for first-pass body-literal
  mutation (`Mut.EnvSnapshot.body_literal_eligible?/1`).
  """
  @spec body_literal_snapshots(t()) :: [EnvSnapshot.t()]
  def body_literal_snapshots(%__MODULE__{by_line: by_line}) do
    by_line
    |> Map.values()
    |> Enum.filter(&EnvSnapshot.body_literal_eligible?/1)
  end

  @doc """
  Constructs a `t:Mut.EnvWalker.tracer_macro_index/0` from the
  project's `Mut.Oracle.DispatchSite` records, filtered to the
  macro dispatch kinds. M39 section "Data Model": the walker
  queries this index on every call node that is not a known
  special form to decide if `if` / `unless` are
  Kernel-control-flow with proof.

  Sites without `column` are still indexed at `column == nil`;
  the walker matches by exact `{file, line, column, name, arity}`
  tuple per the M39 spec.
  """
  @spec build_macro_index([Mut.Oracle.DispatchSite.t()]) :: Mut.EnvWalker.tracer_macro_index()
  def build_macro_index(sites) when is_list(sites) do
    sites
    |> Enum.filter(&macro_kind?(&1.dispatch_kind))
    |> Enum.reduce(%{}, fn site, acc ->
      key = {site.file, site.line, site.column, site.resolved_name, site.resolved_arity}

      Map.put(acc, key, %{
        kind: site.dispatch_kind,
        resolved_module: site.resolved_module,
        resolved_name: site.resolved_name,
        resolved_arity: site.resolved_arity
      })
    end)
  end

  defp macro_kind?(:remote_macro), do: true
  defp macro_kind?(:local_macro), do: true
  defp macro_kind?(:imported_macro), do: true
  defp macro_kind?(_), do: false
end
