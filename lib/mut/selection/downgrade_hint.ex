defmodule Mut.Selection.DowngradeHint do
  @moduledoc """
  Exploratory #64: on macro-heavy target projects, coverage-based test
  selection (the `:coverage_with_static_fallback` default) can burn tens of
  seconds every single run before the pathological-collection check discards
  it and falls back to static selection. Work copies are fresh per run, so
  that tax repeats forever.

  This module persists the downgrade decision to a small JSON hint file under
  the **target project's** `_build/` (a per-project decision the user may
  want to inspect or delete — NOT the run's OS-temp `artifact_root`, which is
  wiped every run). A later `:coverage_with_static_fallback` run reads the
  hint and, if the project is unchanged (same `Mut.History.Digest.project_digest/1`),
  skips coverage collection entirely and goes straight to static selection.

  Like `Mut.History.Store`, this is purely an optimization: a missing,
  unreadable, or malformed hint is treated as "no hint" (never aborts a run),
  and a digest mismatch (the project changed since the downgrade) discards the
  stale hint and lets coverage collection run again — the project may no
  longer be pathological.
  """

  @format_version 1

  alias Mut.History.Digest

  @typedoc "Decoded hint file contents (string keys, as read from JSON)."
  @type hint :: %{optional(String.t()) => term()}

  @doc "Path to the hint file under the target project's `_build/`."
  @spec path(Path.t()) :: Path.t()
  def path(root), do: Path.join([root, "_build", "mut_selection_downgrade.json"])

  @doc """
  Decide whether a `:coverage_with_static_fallback` run should skip coverage
  collection:

    * `{:skip, hint}` — a hint exists and its stored project digest matches
      the CURRENT project digest; the caller should use static selection.
    * `:collect` — no hint, an unreadable/corrupt hint, or a digest mismatch
      (project changed since the downgrade). A stale (digest-mismatched) hint
      is deleted as a side effect so it doesn't linger; a corrupt hint is left
      alone (the next downgrade overwrites it).
  """
  @spec check(Path.t()) :: {:skip, hint()} | :collect
  def check(root) do
    case read(root) do
      {:ok, hint} ->
        current = Digest.project_digest(root)

        if Map.get(hint, "project_digest") == current do
          {:skip, hint}
        else
          delete(root)
          :collect
        end

      :absent ->
        :collect
    end
  end

  @doc """
  Persist a pathological-collection downgrade decision for `root`. Non-fatal:
  any filesystem error is caught and returned as `{:error, reason}` for the
  caller to warn about (at most once) rather than crash the run.
  """
  @spec write(Path.t(), %{
          coverage_wall_ms: non_neg_integer(),
          baseline_tests_ms: non_neg_integer(),
          project_digest: String.t()
        }) :: :ok | {:error, term()}
  def write(root, %{
        coverage_wall_ms: wall_ms,
        baseline_tests_ms: baseline_ms,
        project_digest: digest
      }) do
    payload = %{
      "format_version" => @format_version,
      "tool_version" => tool_version(),
      "coverage_wall_ms" => wall_ms,
      "baseline_tests_ms" => baseline_ms,
      "project_digest" => digest,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    file = path(root)

    File.mkdir_p!(Path.dirname(file))
    tmp = tmp_path(file)
    File.write!(tmp, Mut.JSON.encode!(payload, pretty: true) <> "\n")
    File.rename!(tmp, file)
    :ok
  rescue
    e -> {:error, e}
  end

  @doc """
  Read the hint at `root`. Returns `{:ok, hint}` only when the file exists,
  parses as JSON, and its `format_version` matches this tool's. Any other
  condition (absent, unreadable, malformed, version mismatch) yields
  `:absent` — the caller treats it exactly like "no hint".
  """
  @spec read(Path.t()) :: {:ok, hint()} | :absent
  def read(root) do
    with {:ok, raw} <- File.read(path(root)),
         {:ok, %{"format_version" => @format_version} = decoded} <- Mut.JSON.decode(raw) do
      {:ok, decoded}
    else
      _ -> :absent
    end
  rescue
    _ -> :absent
  end

  @doc "Delete the hint file at `root`, if present. Never raises."
  @spec delete(Path.t()) :: :ok
  def delete(root) do
    root |> path() |> File.rm()
    :ok
  end

  defp tmp_path(file) do
    suffix = :erlang.unique_integer([:positive]) |> Integer.to_string()
    file <> ".#{suffix}.tmp"
  end

  defp tool_version do
    case Application.spec(:mutalisk, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
