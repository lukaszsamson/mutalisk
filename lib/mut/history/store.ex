defmodule Mut.History.Store do
  @moduledoc """
  M105: persistent per-mutant verdict store for incremental cross-run history
  (design in `docs/spikes/M104_incremental_history.md`).

  A JSON file under the **user project's** `_build/mut_history/history.json`
  (configurable). It persists across runs (the work copy does not), never
  touches the user source tree (`_build/` is build-state, git-ignored), and is
  keyed by `stable_id`. Each verdict carries the digests M106 needs to decide
  reuse.

  History is an optimization: a missing, corrupt, or version-mismatched store
  is treated as **cold** (no history) — it must never abort a run or be
  partially trusted ("incorrect reuse is worse than a slow run").
  """

  alias Mut.History.Digest

  @format_version 1
  @default_retention_generations 3

  @typedoc """
  One reusable verdict. `status` is always a reusable one (killed/survived/
  timeout — error/invalid/skipped are never stored).
  """
  @type record :: %{
          stable_id: String.t(),
          status: String.t(),
          source_digest: String.t(),
          selected_tests_digest: String.t(),
          project_digest: String.t(),
          killing_test: String.t() | nil,
          test_timeout_ms: pos_integer() | nil
        }

  @type store :: %{
          format_version: pos_integer(),
          tool_version: String.t(),
          generation: non_neg_integer(),
          verdicts: %{optional(String.t()) => map()}
        }

  @reusable_statuses ~w(killed survived timeout)

  @doc "Default store path under the user project's build directory."
  @spec default_path(Path.t()) :: Path.t()
  def default_path(root), do: Path.join([root, "_build", "mut_history", "history.json"])

  @doc "The store path: `:history_path` opt overrides `default_path(root)`."
  @spec path(Path.t(), keyword()) :: Path.t()
  def path(root, opts \\ []) do
    case Keyword.get(opts, :history_path) do
      nil -> default_path(root)
      configured -> configured
    end
  end

  @doc """
  Load the store at `path`. Returns `{:ok, store}` only when the file exists,
  parses, and its `format_version` + `tool_version` match the running tool.
  Any other condition (absent, unreadable, malformed, version mismatch) yields
  `{:cold, reason}` — the caller starts from an empty store.
  """
  @spec load(Path.t()) :: {:ok, store()} | {:cold, atom()}
  def load(path) do
    with {:ok, raw} <- read_file(path),
         {:ok, decoded} <- decode(raw),
         :ok <- check_versions(decoded) do
      {:ok, from_json(decoded)}
    end
  end

  @doc """
  Build the next store: bump the generation, stamp every record produced this
  run with it, merge over the previous store's verdicts (this run wins), and GC
  entries not seen within `:retention_generations` (default 3) — bounding the
  store at roughly `plan_size × retention`.
  """
  @spec build(store() | :cold, [record()], keyword()) :: store()
  def build(prev, records, opts \\ []) do
    retention = Keyword.get(opts, :retention_generations, @default_retention_generations)
    prev_verdicts = previous_verdicts(prev)
    generation = previous_generation(prev) + 1

    stamped =
      Map.new(records, fn record ->
        {record.stable_id, record |> record_to_entry() |> Map.put("generation", generation)}
      end)

    merged = Map.merge(prev_verdicts, stamped)
    kept = gc(merged, generation, retention)

    %{
      format_version: @format_version,
      tool_version: tool_version(),
      generation: generation,
      verdicts: kept
    }
  end

  @doc "Atomically write the store to `path` (mkdir -p, tmp file, rename)."
  @spec write(Path.t(), store()) :: :ok
  def write(path, store) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Mut.JSON.encode!(to_json(store), pretty: true) <> "\n")
    File.rename!(tmp, path)
    :ok
  end

  @doc "Whether a status is a reusable verdict worth storing."
  @spec reusable_status?(atom() | String.t()) :: boolean()
  def reusable_status?(status), do: to_string(status) in @reusable_statuses

  @doc """
  Build a verdict `record` from a finished mutant. `source_index` is the
  `Mut.History.Digest.function_index/1` for the mutant's file; `read_test`
  reads a relative test path's content (returns `nil` if unreadable).
  Returns `nil` for non-reusable statuses (caller filters).

  `killing_test` is stored as the ExUnit identifier (`"Module test name"`) for
  diagnostics only — it is not a file path, so the reuse gate uses
  `selected_tests_digest` (which, under coverage selection, *is* the covering
  tests) rather than a per-killing-test digest.
  """
  @spec record_for(
          Mut.Mutant.t(),
          Digest.index(),
          (Path.t() -> String.t() | nil),
          pos_integer() | nil,
          String.t()
        ) :: record() | nil
  def record_for(%Mut.Mutant{} = mutant, source_index, read_test, test_timeout_ms, project_digest) do
    if reusable_status?(mutant.status) do
      selected = mutant.covering_tests || []

      selected_entries =
        for path <- selected, content = read_test.(path), do: {path, content}

      %{
        stable_id: mutant.stable_id,
        status: to_string(mutant.status),
        source_digest: Digest.source_digest(source_index, mutant.line),
        selected_tests_digest: Digest.selected_tests_digest(selected_entries),
        project_digest: project_digest,
        killing_test: mutant.killing_test,
        test_timeout_ms: test_timeout_ms
      }
    end
  end

  # ---- internals ----

  defp gc(verdicts, generation, retention) do
    floor_gen = generation - retention

    verdicts
    |> Enum.filter(fn {_id, entry} -> Map.get(entry, "generation", 0) > floor_gen end)
    |> Map.new()
  end

  defp previous_verdicts(:cold), do: %{}
  defp previous_verdicts(%{verdicts: v}), do: v

  defp previous_generation(:cold), do: 0
  defp previous_generation(%{generation: g}), do: g

  defp record_to_entry(record) do
    %{
      "status" => record.status,
      "source_digest" => record.source_digest,
      "selected_tests_digest" => record.selected_tests_digest,
      "project_digest" => record.project_digest,
      "killing_test" => record.killing_test,
      "test_timeout_ms" => record.test_timeout_ms
    }
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, _} -> {:cold, :absent}
    end
  end

  defp decode(raw) do
    {:ok, :json.decode(raw)}
  rescue
    _ -> {:cold, :malformed}
  end

  defp check_versions(%{"format_version" => @format_version, "tool_version" => v}) do
    if v == tool_version(), do: :ok, else: {:cold, :tool_version_mismatch}
  end

  defp check_versions(_), do: {:cold, :format_version_mismatch}

  defp from_json(%{"generation" => gen, "verdicts" => verdicts}) do
    %{
      format_version: @format_version,
      tool_version: tool_version(),
      generation: trunc(gen),
      verdicts: verdicts
    }
  end

  defp to_json(store) do
    %{
      "format_version" => store.format_version,
      "tool_version" => store.tool_version,
      "generation" => store.generation,
      "verdicts" => store.verdicts
    }
  end

  defp tool_version do
    case Application.spec(:mutalisk, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
