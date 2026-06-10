defmodule Mut.History.Digest do
  @moduledoc """
  M105: digest computation for incremental cross-run history (design in
  `docs/spikes/M104_incremental_history.md`).

  Three digests drive the M106 reuse decision:

    * **`source_digest`** — *function-level*. A mutant's verdict invalidates iff
      its enclosing function's source changed (not the whole file, not just the
      mutated span). Computed by building a per-file function index once and
      looking up the function enclosing the mutant's line. Mutants outside any
      named function (module attributes, top-level literals) fall back to the
      whole-file digest (the safe, coarser direction).

    * **`selected_tests_digest`** — order-insensitive, content-sensitive digest
      over a mutant's selected test files. A survivor's verdict depends on every
      selected test, so this hashes the sorted `{path, content_digest}` pairs.

    * **`content_digest`** — a single file's normalized-source digest (used for
      the killing test in killed-verdict reuse).

  All digests use SHA-256/128 hex encoding over AST-canonicalized source
  (parse → `Macro.to_string`), so pure-formatting churn (indentation, blank
  lines, comments) does not invalidate, while a semantic change — including an
  edit *inside* a string/charlist literal — does. The earlier
  collapse-all-whitespace normalization treated `"a  b"` and `"a b"` as
  identical and reused stale verdicts across semantic string edits (R4).
  """

  @typedoc "Opaque per-file function index: line ranges + per-function digests."
  @opaque index :: %{
            ranges: [{pos_integer(), pos_integer(), term()}],
            digests: %{term() => String.t()},
            file_digest: String.t()
          }

  @doc """
  Build the per-file function index from source. Returns an opaque index;
  `source_digest/2` looks up the function enclosing a given line.

  Unparseable source degrades to a file-only index (every line maps to the
  file digest) — the safe direction.
  """
  @spec function_index(String.t()) :: index()
  def function_index(source) when is_binary(source) do
    file_digest = content_digest(source)

    case Code.string_to_quoted(source,
           token_metadata: true,
           columns: true,
           emit_warnings: false
         ) do
      {:ok, ast} ->
        clauses = collect_def_clauses(ast)

        ranges =
          Enum.map(clauses, fn {key, range, _src} -> {elem(range, 0), elem(range, 1), key} end)

        digests = clause_digests(clauses)
        %{ranges: ranges, digests: digests, file_digest: file_digest}

      _ ->
        %{ranges: [], digests: %{}, file_digest: file_digest}
    end
  end

  @doc """
  The function-level source digest for the function enclosing `line`. Falls
  back to the whole-file digest when `line` is in no named function (module
  attribute / top-level position).
  """
  @spec source_digest(index(), pos_integer()) :: String.t()
  def source_digest(%{ranges: ranges, digests: digests, file_digest: file_digest}, line)
      when is_integer(line) do
    ranges
    |> Enum.filter(fn {lo, hi, _key} -> line >= lo and line <= hi end)
    # Smallest enclosing clause wins (nested/anonymous spans), most specific.
    |> Enum.min_by(fn {lo, hi, _key} -> hi - lo end, fn -> nil end)
    |> case do
      {_lo, _hi, key} -> Map.get(digests, key, file_digest)
      nil -> file_digest
    end
  end

  @doc "Normalized-source digest of a single file's content."
  @spec content_digest(String.t()) :: String.t()
  def content_digest(content) when is_binary(content), do: content |> normalize() |> sha()

  @doc """
  Order-insensitive, content-sensitive digest over a mutant's selected tests.

  `entries` is a list of `{relative_path, content}` for each selected test.
  """
  @spec selected_tests_digest([{Path.t(), String.t()}]) :: String.t()
  def selected_tests_digest(entries) when is_list(entries) do
    entries
    |> Enum.map(fn {path, content} -> {to_string(path), content_digest(content)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> sha()
  end

  # Globs (relative to the project root) whose contents form the project
  # fingerprint. `_test.exs` files are excluded — each mutant's *selected* tests
  # are digested per-mutant by `selected_tests_digest/1`, and non-selected test
  # files cannot affect that mutant's verdict.
  #
  # R4: the root-only `lib/** test/** config/**` globs matched nothing under
  # `apps/<app>/...`, so editing an umbrella child left the fingerprint
  # unchanged and a stale verdict was reused. The umbrella layout
  # (`apps/*/{lib,test,config}`, each app's `mix.exs`) is fingerprinted
  # explicitly. `.heex`/`.eex` templates, `lib/**/*.exs`, and `priv` (compiled
  # or read at runtime/compile time) were also unfingerprinted.
  @project_globs [
    "lib/**/*.ex",
    "lib/**/*.exs",
    "lib/**/*.heex",
    "lib/**/*.eex",
    "test/**/*.ex",
    "test/**/*.exs",
    "config/**/*.exs",
    "priv/**/*",
    "apps/*/lib/**/*.ex",
    "apps/*/lib/**/*.exs",
    "apps/*/lib/**/*.heex",
    "apps/*/lib/**/*.eex",
    "apps/*/test/**/*.ex",
    "apps/*/test/**/*.exs",
    "apps/*/config/**/*.exs",
    "apps/*/priv/**/*",
    "apps/*/mix.exs"
  ]
  @project_files ["mix.exs", "mix.lock"]

  @doc """
  Coarse project fingerprint: a digest over every project input that can change
  a mutant's verdict but is **not** captured by the per-mutant function-source
  or selected-test digests — all `lib` source (a mutant's function may call
  helpers in other files), test support/helpers/fixtures (non-`_test.exs`),
  config, and the dependency lock (`mix.lock`/`mix.exs`).

  A change to any of these invalidates **all** reuse. This is the
  conservative-correct first version: "incorrect reuse is worse than a slow
  run." It deliberately over-invalidates — a one-file edit invalidates the whole
  store — because Mutalisk does not (yet) track per-mutant call-graph
  dependencies. Dependency-aware fingerprints that restore per-function
  diff-scoped reuse are future work.
  """
  @spec project_digest(Path.t()) :: String.t()
  def project_digest(root) when is_binary(root) do
    globbed = Enum.flat_map(@project_globs, &Path.wildcard(Path.join(root, &1)))
    extra = Enum.map(@project_files, &Path.join(root, &1))

    (globbed ++ extra)
    |> Enum.reject(&String.ends_with?(&1, "_test.exs"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), content_digest(File.read!(path))} end)
    |> :erlang.term_to_binary()
    |> sha()
  end

  # ---- internals ----

  # Each `def`/`defp` clause -> {function-key, {lo_line, hi_line}, normalized_src}.
  # Multi-clause functions yield one entry per clause sharing the same key.
  defp collect_def_clauses(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head | _]} = node, acc when def_kind in [:def, :defp] ->
          key = def_key(def_kind, head)
          {node, [{key, node_line_range(node), Macro.to_string(node)} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Combined digest per function-key: concatenate all clause sources (sorted by
  # start line for determinism) and hash. Editing any clause of foo/1
  # invalidates every mutant in foo/1 (clauses are not independent — a new
  # clause can shadow a later one), which is the safe unit.
  defp clause_digests(clauses) do
    clauses
    |> Enum.group_by(fn {key, _range, _src} -> key end)
    |> Map.new(fn {key, group} ->
      # `src` is already `Macro.to_string(node)` — AST-canonical, so formatting
      # churn is neutralized and string-literal contents are preserved (no
      # whitespace re-collapse here; R4).
      combined =
        group
        |> Enum.sort_by(fn {_key, {lo, _hi}, _src} -> lo end)
        |> Enum.map_join("\n", fn {_key, _range, src} -> src end)

      {key, sha(combined)}
    end)
  end

  defp def_key(def_kind, {:when, _, [head | _]}), do: def_key(def_kind, head)

  defp def_key(def_kind, {name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {def_kind, name, arity}
  end

  defp def_key(def_kind, other), do: {def_kind, Macro.to_string(other)}

  # Min/max `:line` over the whole subtree — the true line span of the clause,
  # robust across block (`do...end`) and keyword (`, do:`) def forms.
  defp node_line_range(node) do
    lines = collect_lines(node)

    case lines do
      [] -> {0, 0}
      _ -> {Enum.min(lines), Enum.max(lines)}
    end
  end

  defp collect_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case Keyword.get(meta, :line) do
            line when is_integer(line) -> {node, [line | acc]}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines
  end

  # Normalize source so pure-formatting churn (indentation, blank lines,
  # comments) does not invalidate reuse, while a SEMANTIC change — including an
  # edit *inside* a string/charlist literal or heredoc — does (R4). The old
  # `String.replace(~r/\s+/, " ")` collapsed whitespace EVERYWHERE, so editing
  # the contents of `"a  b"` to `"a b"` produced an identical digest and reused
  # a stale verdict. Round-tripping through the AST canonicalizes code layout
  # while preserving literal contents exactly. Non-Elixir or unparseable input
  # (e.g. a binary `priv` asset) falls back to the raw bytes — the safe,
  # over-invalidating direction.
  defp normalize(source) when is_binary(source) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, ast} -> Macro.to_string(ast)
      _ -> source
    end
  end

  defp sha(bin),
    do: :sha256 |> :crypto.hash(bin) |> binary_part(0, 16) |> Base.encode16(case: :lower)
end
