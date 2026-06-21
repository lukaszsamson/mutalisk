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
    # Tie-break by the key term so equal-span clauses always resolve to the same
    # entry regardless of AST traversal order (R: non-deterministic digest).
    |> Enum.min_by(fn {lo, hi, key} -> {hi - lo, key} end, fn -> nil end)
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
    # All of `test/**` (not just `*.ex[s]`): a non-Elixir fixture a selected
    # test reads (`test/fixtures/*.json`, `.csv`, `.pem`, snapshots) changes the
    # mutant's verdict but would otherwise leave the fingerprint unchanged.
    # `_test.exs` is rejected below (covered per-mutant by selected_tests_digest).
    "test/**/*",
    "config/**/*.exs",
    "priv/**/*",
    "apps/*/lib/**/*.ex",
    "apps/*/lib/**/*.exs",
    "apps/*/lib/**/*.heex",
    "apps/*/lib/**/*.eex",
    "apps/*/test/**/*",
    "apps/*/config/**/*.exs",
    "apps/*/priv/**/*",
    "apps/*/mix.exs",
    # In an overlayed work copy the user's real `mix.exs` is renamed to
    # `mix_user.exs` (the generated overlay takes the `mix.exs` name). Fingerprint
    # it so a dep/config/application change in the user's mix.exs invalidates
    # reuse even when it doesn't touch `mix.lock`.
    "apps/*/mix_user.exs"
  ]
  @project_files ["mix.exs", "mix.lock", "mix_user.exs"]

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
    # `match_dot: true` so inputs under dot-directories or with dotfile names
    # (`priv/.migrations/*`, `config/.runtime/*.exs`, `priv/.gz_assets/*`) are
    # fingerprinted too — otherwise an edit to one leaves the project digest
    # unchanged and a stale verdict is reused (R4 soundness gap).
    globbed = Enum.flat_map(@project_globs, &Path.wildcard(Path.join(root, &1), match_dot: true))
    extra = Enum.map(@project_files, &Path.join(root, &1))

    (globbed ++ extra)
    |> Enum.reject(&(String.ends_with?(&1, "_test.exs") or String.contains?(&1, "/.git/")))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), input_digest(path)} end)
    |> :erlang.term_to_binary()
    |> sha()
  end

  # Elixir source is AST-normalized (via `content_digest`) so cosmetic churn —
  # comments, reformatting — doesn't needlessly invalidate reuse. Every other
  # input (priv assets, data files) is hashed BYTE-EXACT: a file the app reads
  # verbatim has no "irrelevant formatting", and AST-normalizing one that happens
  # to parse as Elixir (`priv/rates.txt` = `1.50` -> `1.5`) would silently
  # collapse a behaviour-affecting change and reuse a stale verdict (R4).
  defp input_digest(path) do
    content = File.read!(path)
    if elixir_source?(path), do: content_digest(content), else: sha(content)
  end

  defp elixir_source?(path), do: String.ends_with?(path, [".ex", ".exs", ".heex", ".eex"])

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
  # while preserving literal contents exactly. Non-Elixir, unparseable, or
  # NON-UTF-8 input (e.g. a binary `priv` asset — an image, gzip, seed DB; now
  # fingerprinted by the M116/R4 `priv/**/*` glob) falls back to the raw bytes,
  # the safe over-invalidating direction. The `String.valid?/1` guard is
  # essential: `Code.string_to_quoted/2` runs `String.to_charlist/1`, which
  # *raises* `UnicodeConversionError` on invalid UTF-8 rather than returning an
  # error tuple — that crashed `project_digest` on the first binary priv file.
  defp normalize(source) when is_binary(source) do
    if String.valid?(source) do
      case Code.string_to_quoted(source, emit_warnings: false) do
        {:ok, ast} -> Macro.to_string(ast)
        _ -> source
      end
    else
      source
    end
  end

  defp sha(bin),
    do: :sha256 |> :crypto.hash(bin) |> binary_part(0, 16) |> Base.encode16(case: :lower)
end
