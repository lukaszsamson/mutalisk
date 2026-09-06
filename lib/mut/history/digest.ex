defmodule Mut.History.Digest do
  @moduledoc """
  M105: digest computation for incremental cross-run history.

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
  @root_project_globs [
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
    "priv/**/*"
  ]
  @project_files ["mix.exs", "mix.lock", "mix_user.exs"]

  # Subtrees (plus the root files below) of a `path:` dependency that are
  # compiled or read with the target and therefore belong in the fingerprint.
  # `_build`, `deps` and `.git` are excluded everywhere inside them: they are
  # build state / vendored copies, not the dependency's own source.
  @path_dep_subtrees ["lib", "src", "config", "priv"]
  @path_dep_root_files ["mix.exs", "mix.lock"]
  @path_dep_pruned_segments ["_build", "deps", ".git"]

  # Source roots already covered by @root_project_globs / @apps_child_globs, so
  # an `elixirc_paths: ["lib"]` declaration adds nothing (and, crucially, does
  # not perturb the digest of a project that merely spells out the default).
  @fingerprinted_roots ["lib", "test", "config", "priv"]

  # Child-app-relative globs, joined under the umbrella's configured apps
  # directory (see `apps_project_globs/1`). Hard-coding the `apps/*` prefix
  # here left umbrellas with a custom `:apps_path` (e.g. `apps_path:
  # "packages"`) unfingerprinted: an edit under `packages/foo/lib` changed
  # nothing the wildcard matched, so a stale verdict was reused (T18).
  @apps_child_globs [
    "lib/**/*.ex",
    "lib/**/*.exs",
    "lib/**/*.heex",
    "lib/**/*.eex",
    "test/**/*",
    "config/**/*.exs",
    "priv/**/*",
    "mix.exs",
    # In an overlayed work copy the user's real `mix.exs` is renamed to
    # `mix_user.exs` (the generated overlay takes the `mix.exs` name). Fingerprint
    # it so a dep/config/application change in the user's mix.exs invalidates
    # reuse even when it doesn't touch `mix.lock`.
    "mix_user.exs"
  ]

  # Globs for umbrella child apps, rooted at the work copy's configured
  # `:apps_path` (default `"apps"`) rather than the literal `"apps"` prefix.
  defp apps_project_globs(root) do
    apps_dir = Mut.Umbrella.apps_path_name(root)
    Enum.map(@apps_child_globs, &Path.join([apps_dir, "*", &1]))
  end

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
  def project_digest(root) when is_binary(root), do: digest_with(root, scan(root, nil))

  @doc """
  The project fingerprint **plus the reuse gate**: `{:ok, digest}` when every
  project input could be accounted for, or `{:disable, reasons}` when it could
  not and reuse must be switched off for the whole run.

  `mix.exs` and `mix.lock` alone cannot identify the *contents* of a
  `path:` dependency (`{:local_dep, path: "local_dep"}`): the dependency is
  compiled with the target, so editing `local_dep/lib/local_dep.ex` flips
  verdicts while changing neither Mix file (F6). `project_digest/1` therefore
  also hashes every file under each resolved path dependency's `lib`, `src`,
  `config` and `priv` (plus its own `mix.exs`/`mix.lock`), byte-exact, and
  every extra `:elixirc_paths` source root.

  A `path:` value that is not a literal string (or a module attribute holding
  one) — `path: System.get_env("DEP")`, `path: Path.expand(...)` — cannot be
  resolved syntactically, and neither can an unparseable `mix.exs`. Those
  inputs are invisible to the fingerprint, so instead of silently reusing
  against an incomplete digest this returns `{:disable, reasons}` and the
  caller runs every mutant (printing the reasons). "Incorrect reuse is worse
  than a slow run."
  """
  @spec project_fingerprint(Path.t(), keyword) :: {:ok, String.t()} | {:disable, [String.t()]}
  def project_fingerprint(root, opts \\ []) when is_binary(root) do
    scan = scan(root, Keyword.get(opts, :user_root))

    case scan.reasons do
      [] -> {:ok, digest_with(root, scan)}
      reasons -> {:disable, reasons}
    end
  end

  defp digest_with(root, scan) do
    # `match_dot: true` so inputs under dot-directories or with dotfile names
    # (`priv/.migrations/*`, `config/.runtime/*.exs`, `priv/.gz_assets/*`) are
    # fingerprinted too — otherwise an edit to one leaves the project digest
    # unchanged and a stale verdict is reused (R4 soundness gap).
    all_globs = @root_project_globs ++ apps_project_globs(root) ++ scan.globs
    globbed = Enum.flat_map(all_globs, &Path.wildcard(Path.join(root, &1), match_dot: true))
    extra = Enum.map(@project_files, &Path.join(root, &1))

    file_entries =
      (globbed ++ extra)
      |> Enum.reject(&(String.ends_with?(&1, "_test.exs") or String.contains?(&1, "/.git/")))
      |> Enum.filter(&File.regular?/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn path -> {Path.relative_to(path, root), input_digest(path)} end)

    # Appended, never interleaved, and EMPTY for a project with no path
    # dependencies — so the digest of such a project is byte-identical to the
    # pre-F6 one and warm histories survive the upgrade.
    (file_entries ++ path_dep_entries(scan.deps))
    |> :erlang.term_to_binary()
    |> sha()
  end

  # Elixir source is AST-normalized (via `content_digest`) so cosmetic churn —
  # comments, reformatting — doesn't needlessly invalidate reuse. Every other
  # input (priv assets, data files, and `.eex`/`.heex` templates) is hashed
  # BYTE-EXACT: a file the app reads verbatim has no "irrelevant formatting",
  # and AST-normalizing one that happens to parse as Elixir (`priv/rates.txt` =
  # `1.50` -> `1.5`) would silently collapse a behaviour-affecting change and
  # reuse a stale verdict (R4). `.eex`/`.heex` templates are EEx source, not
  # Elixir source: `Code.string_to_quoted/2` only sees the literal (non-`<%
  # %>`) text as an Elixir-ish token stream and `Macro.to_string/1` can
  # re-print it losing whitespace/attribute-quoting that is significant in
  # HTML/EEx (e.g. `1.50` -> `1.5` inside a tag, or collapsed inter-tag
  # whitespace) — a behaviour-affecting byte edit collapsing to the same
  # digest and reusing a stale verdict (T19).
  defp input_digest(path) do
    content = File.read!(path)
    if elixir_source?(path), do: content_digest(content), else: sha(content)
  end

  defp elixir_source?(path), do: String.ends_with?(path, [".ex", ".exs"])

  # ---- F6: path dependencies and extra source roots ----

  # Everything read out of the project's own `mix.exs` files: the resolved
  # `path:` dependency roots, the extra `:elixirc_paths` source-root globs, and
  # the reasons reuse must be disabled. An umbrella is scanned PER CHILD APP
  # (each child declares its own deps and elixirc_paths) plus the root.
  defp scan(root, user_root) do
    [root | umbrella_app_dirs(root)]
    |> Enum.uniq()
    |> Enum.reduce(%{deps: [], globs: [], reasons: []}, fn dir, acc ->
      scanned = scan_mix(dir, root, user_root)

      %{
        deps: acc.deps ++ scanned.deps,
        globs: acc.globs ++ scanned.globs,
        reasons: acc.reasons ++ scanned.reasons
      }
    end)
  end

  # `Mut.Umbrella.app_dirs/1` parses the root mix.exs with
  # `Code.string_to_quoted!/1` and raises on an unparseable one. That case is
  # already reported by `scan_mix/2` for the root itself (and disables reuse),
  # so here it just means "no child apps discoverable".
  defp umbrella_app_dirs(root) do
    Mut.Umbrella.app_dirs(root)
  rescue
    _ -> []
  end

  defp scan_mix(dir, root, user_root) do
    empty = %{deps: [], globs: [], reasons: []}
    mix_path = user_mix_path(dir)

    if File.regular?(mix_path) do
      case Code.string_to_quoted(File.read!(mix_path), emit_warnings: false) do
        {:ok, ast} -> scan_ast(ast, dir, root, mix_path, user_root)
        _ -> %{empty | reasons: ["#{Path.relative_to(mix_path, root)} could not be parsed"]}
      end
    else
      empty
    end
  end

  defp scan_ast(ast, dir, root, mix_path, user_root) do
    attrs = attr_literals(ast)
    owner = owner_prefix(dir, root)
    rel_mix = Path.relative_to(mix_path, root)
    # A work copy is a tree copy of the project, so `path: "../shared"` (a
    # sibling OUTSIDE the project) does not exist next to it; resolve such
    # deps against the same directory in the user's real project instead.
    user_dir = user_root && Path.join([user_root | owner])

    {deps, reasons} =
      ast
      |> collect_path_deps(attrs, dir)
      |> Enum.reduce({[], []}, fn {name, value}, {deps, reasons} ->
        case resolve_dep_root(value, dir, user_dir) do
          {:ok, dep_root} ->
            {[{{owner, Atom.to_string(name)}, dep_root} | deps], reasons}

          {:error, detail} ->
            {deps, [~s(path dependency :#{name} in #{rel_mix} #{detail}) | reasons]}
        end
      end)

    globs =
      for source_root <- source_roots(ast),
          do: Path.join(owner ++ [source_root, "**/*"])

    %{deps: Enum.reverse(deps), globs: globs, reasons: Enum.reverse(reasons)}
  end

  # Path segments locating `dir` inside `root` (`[]` for the root project,
  # `["apps", "web"]` for an umbrella child). Used both to key a dependency's
  # entries and to root its extra source-root globs.
  defp owner_prefix(dir, root) do
    case Path.relative_to(dir, root) do
      ^dir -> Path.split(dir)
      rel when rel in [".", ""] -> []
      rel -> Path.split(rel)
    end
  end

  defp user_mix_path(dir) do
    user = Path.join(dir, "mix_user.exs")
    if File.regular?(user), do: user, else: Path.join(dir, "mix.exs")
  end

  # Dependency tuples anywhere in the mix.exs carrying a `path:` option, in
  # both the 2-tuple (`{:dep, path: "..."}`) and 3-tuple
  # (`{:dep, "~> 1.0", path: "..."}`) forms. The walk is deliberately
  # structure-based rather than tied to `deps/0`: the list may live in `def
  # deps`, `defp deps`, a `@deps` attribute, or be spliced together — and an
  # over-approximation only ever fingerprints more than needed.
  # Only the dependency declarations count: the bodies of `def(p) deps` and
  # a `@deps` attribute value. Walking the whole file mis-read `escript:
  # [path: ...]` / `releases: [x: [path: ...]]` (and any other keyword with a
  # `:path` key) as path dependencies, and an unresolvable one DISABLES reuse
  # for the whole run — so this over-approximation is not harmless. A file
  # with no recognisable deps declaration falls back to the whole AST.
  defp collect_path_deps(ast, attrs, dir) do
    scope =
      case deps_declarations(ast) do
        [] -> ast
        declarations -> declarations
      end

    {_ast, acc} =
      Macro.prewalk(scope, [], fn
        {name, opts} = node, acc when is_atom(name) and is_list(opts) ->
          {node, prepend_path_dep(acc, name, opts, attrs, dir)}

        {:{}, _meta, [name, _req, opts]} = node, acc when is_atom(name) and is_list(opts) ->
          {node, prepend_path_dep(acc, name, opts, attrs, dir)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp deps_declarations(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [{:deps, _, _args}, body]} = node, acc when def_kind in [:def, :defp] ->
          {node, [body | acc]}

        {:@, _meta, [{:deps, _, [value]}]} = node, acc ->
          {node, [value | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp prepend_path_dep(acc, name, opts, attrs, dir) do
    case Enum.find(opts, fn entry -> match?({:path, _value}, entry) end) do
      {:path, value} -> [{name, resolve_path_expr(value, attrs, dir)} | acc]
      _other -> acc
    end
  end

  # `path:` values are frequently small expressions rather than literals —
  # `System.get_env("DEP_PATH") || Path.expand("../dep", __DIR__)` is the
  # idiom for "local checkout if configured, else the vendored copy". A tiny
  # evaluator covers that idiom (literals, `@attr`, `__DIR__`, `||`,
  # `System.get_env/1,2`, `Path.expand/1,2`, `Path.join/1,2`) using THIS
  # process's environment, which is the environment the run itself uses.
  # Anything else stays `:unresolved` and disables reuse.
  defp resolve_path_expr(value, attrs, dir) do
    case eval_path_expr(value, attrs, dir) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _nil_or_unresolved -> :unresolved
    end
  end

  defp eval_path_expr(value, attrs, _dir) when is_binary(value) or is_atom(value),
    do: resolve_literal(value, attrs)

  defp eval_path_expr({:@, _, _} = attr_read, attrs, _dir), do: resolve_literal(attr_read, attrs)
  defp eval_path_expr({:__DIR__, _meta, ctx}, _attrs, dir) when is_atom(ctx), do: {:ok, dir}

  defp eval_path_expr({:||, _meta, [left, right]}, attrs, dir) do
    case eval_path_expr(left, attrs, dir) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> eval_path_expr(right, attrs, dir)
      :unresolved -> :unresolved
    end
  end

  defp eval_path_expr({{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, args}, attrs, dir) do
    case Enum.map(args, &eval_path_expr(&1, attrs, dir)) do
      [{:ok, name}] when is_binary(name) -> {:ok, System.get_env(name)}
      [{:ok, name}, {:ok, default}] when is_binary(name) -> {:ok, System.get_env(name, default)}
      _other -> :unresolved
    end
  end

  defp eval_path_expr({{:., _, [{:__aliases__, _, [:Path]}, fun]}, _, args}, attrs, dir)
       when fun in [:expand, :join] do
    args
    |> Enum.map(&eval_path_expr(&1, attrs, dir))
    |> path_call(fun, dir)
  end

  defp eval_path_expr(parts, attrs, dir) when is_list(parts) do
    # `Path.join(["a", "b"])`'s list argument.
    parts
    |> Enum.map(&eval_path_expr(&1, attrs, dir))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, p}, {:ok, acc} when is_binary(p) -> {:cont, {:ok, [p | acc]}}
      _other, _acc -> {:halt, :unresolved}
    end)
    |> case do
      {:ok, acc} -> {:ok, Path.join(Enum.reverse(acc))}
      :unresolved -> :unresolved
    end
  end

  defp eval_path_expr(_other, _attrs, _dir), do: :unresolved

  defp path_call([{:ok, path}], :expand, dir) when is_binary(path),
    do: {:ok, Path.expand(path, dir)}

  defp path_call([{:ok, path}, {:ok, base}], :expand, _dir)
       when is_binary(path) and is_binary(base),
       do: {:ok, Path.expand(path, base)}

  defp path_call([{:ok, a}, {:ok, b}], :join, _dir) when is_binary(a) and is_binary(b),
    do: {:ok, Path.join(a, b)}

  defp path_call([{:ok, joined}], :join, _dir) when is_binary(joined), do: {:ok, joined}
  defp path_call(_args, _fun, _dir), do: :unresolved

  defp resolve_dep_root(:unresolved, _dir, _user_dir),
    do: {:error, "has a non-literal `path:` expression, so its contents cannot be fingerprinted"}

  defp resolve_dep_root({:ok, path}, dir, user_dir) do
    candidates =
      [Path.expand(path, dir)] ++ if(user_dir, do: [Path.expand(path, user_dir)], else: [])

    case Enum.find(candidates, &File.dir?/1) do
      nil -> {:error, "points at missing #{path}"}
      dep_root -> {:ok, dep_root}
    end
  end

  # `{owner, dep_name, path_inside_dep} => byte digest` for every resolved path
  # dependency. BYTE-EXACT (not AST-normalized): a dependency's `priv` assets
  # and config are read verbatim, and normalizing an `.ex` here would buy
  # nothing beyond the per-file churn tolerance the target's own sources get.
  defp path_dep_entries([]), do: []

  defp path_dep_entries(deps) do
    deps
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn {{owner, name}, dep_root} ->
      Enum.map(dep_files(dep_root), fn path ->
        {{:path_dep, owner, name, Path.relative_to(path, dep_root)}, sha(File.read!(path))}
      end)
    end)
  end

  defp dep_files(dep_root) do
    subtrees =
      Enum.flat_map(@path_dep_subtrees, fn sub ->
        Path.wildcard(Path.join([dep_root, sub, "**/*"]), match_dot: true)
      end)

    root_files = Enum.map(@path_dep_root_files, &Path.join(dep_root, &1))

    (subtrees ++ root_files)
    |> Enum.reject(&pruned_dep_path?(&1, dep_root))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pruned_dep_path?(path, dep_root) do
    path
    |> Path.relative_to(dep_root)
    |> Path.split()
    |> Enum.any?(&(&1 in @path_dep_pruned_segments))
  end

  # Additional production source roots declared via `:elixirc_paths`, in both
  # supported spellings: the literal list (`elixirc_paths: ["lib", "src"]`) and
  # the `elixirc_paths(Mix.env())` function form, where the UNION of every
  # literal directory across all clauses is taken (over-approximating is safe —
  # a root that does not exist contributes no files).
  defp source_roots(ast) do
    (keyword_source_roots(ast) ++ function_source_roots(ast))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @fingerprinted_roots))
    |> Enum.filter(&relative_dir?/1)
    |> Enum.sort()
  end

  defp keyword_source_roots(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:elixirc_paths, value} = node, acc when is_list(value) ->
          {node, Enum.filter(value, &is_binary/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp function_source_roots(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{:elixirc_paths, _, args} | _rest]} = node, acc
        when kind in [:def, :defp] and (is_nil(args) or is_list(args)) ->
          {node, collect_binaries(node) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp collect_binaries(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        node, acc when is_binary(node) -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp relative_dir?(path) do
    path != "" and Path.type(path) == :relative and
      not Enum.any?(Path.split(path), &(&1 in ["..", "."]))
  end

  # A literal string, or a module attribute bound to one (`@dep_path "x"`).
  defp resolve_literal(value, _attrs) when is_binary(value), do: {:ok, value}
  defp resolve_literal(nil, _attrs), do: {:ok, nil}

  defp resolve_literal({:@, _meta, [{attr, _, ctx}]}, attrs)
       when is_atom(attr) and (is_nil(ctx) or is_atom(ctx)) do
    case Map.fetch(attrs, attr) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _other -> :unresolved
    end
  end

  defp resolve_literal(_value, _attrs), do: :unresolved

  # `@dep_path "../local_dep"` definitions (last write wins, as in Elixir).
  defp attr_literals(ast) do
    {_ast, map} =
      Macro.prewalk(ast, %{}, fn
        {:@, _meta, [{name, _, [value]}]} = node, acc when is_atom(name) and is_binary(value) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    map
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
