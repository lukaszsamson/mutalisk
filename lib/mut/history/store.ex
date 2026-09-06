defmodule Mut.History.Store do
  @moduledoc """
  M105: persistent per-mutant verdict store for incremental cross-run history.

  A JSON file under the **user project's** `_build/mut_history/history.json`
  (configurable). It persists across runs (the work copy does not), never
  touches the user source tree (`_build/` is build-state, git-ignored), and is
  keyed by `stable_id`. Each verdict carries the digests M106 needs to decide
  reuse.

  History is an optimization: a missing, corrupt, or version-mismatched store
  is treated as **cold** (no history) — it must never abort a run or be
  partially trusted ("incorrect reuse is worse than a slow run").

  ## Format versions

    * `1` — the original shape; verdict entries carry `test_timeout_ms` only.
    * `2` (current) — entries additionally carry `suite_timeout_ms` (the
      `--suite-timeout-ms` host deadline budget, `nil` when unset) and
      `killing_test_file` (the authoritative killing test file, `nil` when the
      runner did not report one).

  A store written by an older format version is rejected wholesale by
  `load/1` (`{:cold, :format_version_mismatch}`), so an upgrade simply starts
  cold. Independently of that, an individual entry that lacks
  `suite_timeout_ms` is treated as `nil` by `Mut.History.Reuse` — i.e. it is
  reusable only while the current run has NO `--suite-timeout-ms` set, and is
  rejected as soon as one is configured. Never assume a missing field means
  "matches"; that is the difference between a slow run and an incorrect one.
  """

  alias Mut.History.Digest

  @format_version 2
  @default_retention_generations 3

  @typedoc """
  One reusable verdict. `status` is always a reusable one (killed/survived/
  timeout — error/invalid/skipped are never stored).
  """
  @type verdict_record :: %{
          stable_id: String.t(),
          status: String.t(),
          source_digest: String.t(),
          selected_tests_digest: String.t(),
          project_digest: String.t(),
          killing_test: String.t() | nil,
          killing_test_file: String.t() | nil,
          test_timeout_ms: pos_integer() | nil,
          suite_timeout_ms: pos_integer() | nil
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
      nil ->
        default_path(root)

      # Expand a relative override against `root` so load (in the user project's
      # cwd) and write (under `File.cd!(mutalisk_root, ...)`) resolve to the SAME
      # absolute file — otherwise a relative `history_path` reads one file and
      # writes another and reuse never warms. Absolute paths pass through.
      configured ->
        Path.expand(configured, root)
    end
  end

  @doc """
  Load the store at `path`. Returns `{:ok, store}` only when the file exists,
  parses, and its `format_version` + `tool_version` match the running tool.
  Any other condition (absent, unreadable, malformed, version mismatch) yields
  `{:cold, reason}` — the caller starts from an empty store.

  The decoded store is validated in full (F8): a wrong top-level shape — a
  non-integer `generation`, a `verdicts` that is not a map — is
  `{:cold, :malformed}`, and individually invalid verdict entries are dropped
  (their count printed once) so the rest of the store stays reusable. Nothing
  unvalidated reaches the pipeline, which would otherwise crash on it long
  after the expensive baseline and coverage phases.
  """
  @spec load(Path.t()) :: {:ok, store()} | {:cold, atom()}
  def load(path) do
    with {:ok, raw} <- read_file(path),
         {:ok, decoded} <- decode(raw),
         :ok <- check_versions(decoded) do
      # R/F8: any structural problem must yield cold-start, never crash — not
      # here and not later in the pipeline. `from_json/1` validates the whole
      # decoded store; the rescue stays as a backstop for an input shape that
      # still surprises it.
      try do
        from_json(decoded)
      rescue
        _ -> {:cold, :malformed}
      end
    end
  end

  @doc """
  Build the next store: bump the generation, stamp every record produced this
  run with it, merge over the previous store's verdicts (this run wins), and GC
  entries not seen within `:retention_generations` (default 3) — bounding the
  store at roughly `plan_size × retention`.
  """
  @spec build(store() | :cold, [verdict_record()], keyword()) :: store()
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
    tmp = tmp_path(path)
    File.write!(tmp, Mut.JSON.encode!(to_json(store), pretty: true) <> "\n")
    File.rename!(tmp, path)
    :ok
  end

  defp tmp_path(path) do
    suffix = :erlang.unique_integer([:positive]) |> Integer.to_string()
    path <> ".#{suffix}.tmp"
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
  tests) rather than a per-killing-test digest. `killing_test_file` is the
  authoritative test FILE the killer lived in (when the runner reported one);
  it is what the Stryker reporter turns into `killedBy`, so a reused verdict
  keeps its `killedBy` instead of falling back to the module-name heuristic.

  `timeouts` is `{test_timeout_ms, suite_timeout_ms}` — BOTH deadline budgets,
  because either one can change a verdict (see `Mut.History.Reuse`).
  """
  @spec record_for(
          Mut.Mutant.t(),
          Digest.index(),
          (Path.t() -> String.t() | nil),
          {pos_integer() | nil, pos_integer() | nil},
          String.t()
        ) :: verdict_record() | nil
  def record_for(
        %Mut.Mutant{} = mutant,
        source_index,
        read_test,
        {test_timeout_ms, suite_timeout_ms},
        project_digest
      ) do
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
        killing_test_file: mutant.killing_test_file,
        test_timeout_ms: test_timeout_ms,
        suite_timeout_ms: suite_timeout_ms
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
      "killing_test_file" => record.killing_test_file,
      "test_timeout_ms" => record.test_timeout_ms,
      "suite_timeout_ms" => record.suite_timeout_ms
    }
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, _} -> {:cold, :absent}
    end
  end

  defp decode(raw) do
    # Use `Mut.JSON` (bridges Elixir's built-in `JSON`, OTP 25+) — NOT Erlang's
    # `:json`, which only exists on OTP 27+ and would make every load a silent
    # cold start on OTP 26. Symmetric with `write/1`, which encodes via Mut.JSON.
    case Mut.JSON.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:cold, :malformed}
    end
  rescue
    _ -> {:cold, :malformed}
  end

  defp check_versions(%{"format_version" => @format_version, "tool_version" => v}) do
    if v == tool_version(), do: :ok, else: {:cold, :tool_version_mismatch}
  end

  defp check_versions(_), do: {:cold, :format_version_mismatch}

  # F8: a store that is syntactically valid JSON with the right versions can
  # still be structurally wrong (`"verdicts": []`, a string `"generation"`, an
  # entry whose `status` is `"error"` or whose digests are numbers). Trusting
  # it used to return `{:ok, store}` and crash the pipeline much later —
  # `map_size/1` on a list — AFTER the expensive baseline and coverage phases,
  # instead of the documented cold start. Everything is validated up front:
  #
  #   * a wrong top-level shape (missing/!integer `generation`, non-map
  #     `verdicts`, non-binary keys) => `{:cold, :malformed}`, a cold start;
  #   * an individually invalid ENTRY is DROPPED (the rest of the store is
  #     still perfectly reusable), and the caller is told how many went.
  defp from_json(%{"generation" => gen, "verdicts" => verdicts})
       when is_integer(gen) and is_map(verdicts) do
    kept = Map.filter(verdicts, fn {id, entry} -> is_binary(id) and valid_entry?(entry) end)
    report_dropped(map_size(verdicts) - map_size(kept))

    {:ok,
     %{
       format_version: @format_version,
       tool_version: tool_version(),
       generation: gen,
       verdicts: kept
     }}
  end

  defp from_json(_decoded), do: {:cold, :malformed}

  defp report_dropped(0), do: :ok

  defp report_dropped(count) do
    IO.puts(
      :stderr,
      "[mutalisk] history: dropped #{count} malformed verdict " <>
        "#{if count == 1, do: "entry", else: "entries"}"
    )
  end

  # Every field `Mut.History.Reuse` compares and every field the reused result
  # is rebuilt from. `status` must be one of the reusable statuses: anything
  # else would blow up `String.to_existing_atom/1` (or silently record a bogus
  # status) when the verdict is adopted. `generation` is the GC key, so a
  # non-integer would make retention meaningless.
  defp valid_entry?(entry) when is_map(entry) do
    is_binary(entry["source_digest"]) and
      is_binary(entry["selected_tests_digest"]) and
      is_binary(entry["project_digest"]) and
      entry["status"] in @reusable_statuses and
      optional?(entry["killing_test"], &is_binary/1) and
      optional?(entry["killing_test_file"], &is_binary/1) and
      optional?(entry["test_timeout_ms"], &is_integer/1) and
      optional?(entry["suite_timeout_ms"], &is_integer/1) and
      optional?(entry["generation"], &is_integer/1)
  end

  defp valid_entry?(_entry), do: false

  # A key that is absent or explicitly `null` is fine (format-1 entries carry
  # no `suite_timeout_ms`; a mutant killed with no reported test carries no
  # `killing_test`) — `Mut.History.Reuse` treats `nil` as "unset", not "match".
  defp optional?(nil, _fun), do: true
  defp optional?(value, fun), do: fun.(value)

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
