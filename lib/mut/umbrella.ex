defmodule Mut.Umbrella do
  @moduledoc """
  Umbrella-project detection over a materialized work copy (M67).

  A work copy is an umbrella when its root `mix.exs`/`mix_user.exs` project
  declares `:apps_path`. The single-app path never satisfies this, so every
  predicate here returns the single-app answer (`false` / `[]`) for ordinary
  projects — the umbrella branches are strictly additive.
  """

  @default_apps_path "apps"

  @doc "True when the work copy's root project is an `apps_path` umbrella."
  @spec umbrella?(Path.t()) :: boolean
  def umbrella?(work_copy) do
    case root_project_ast(work_copy) do
      {:ok, ast} -> apps_path_value(ast) != nil
      :error -> false
    end
  end

  @doc """
  Absolute directories of the umbrella's child apps (those carrying a
  `mix.exs` or `mix_user.exs`). `[]` for single-app projects.
  """
  @spec app_dirs(Path.t()) :: [Path.t()]
  def app_dirs(work_copy) do
    case root_project_ast(work_copy) do
      {:ok, ast} ->
        apps_dir = apps_path_value(ast) || @default_apps_path

        work_copy
        |> Path.join(apps_path_glob(apps_dir))
        |> Path.wildcard()
        |> Enum.filter(&mix_project_dir?/1)
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @doc """
  Default project-relative test directories for a work copy: `["test"]` for a
  single app, or each child app's `<apps_path>/<app>/test` for an umbrella (the
  umbrella root has no `test/` of its own). Mirrors the source-discovery split
  in `Mut.Orchestrator`. Used when no explicit `test_paths` is configured.
  """
  @spec default_test_dirs(Path.t()) :: [Path.t()]
  def default_test_dirs(work_copy) do
    if umbrella?(work_copy) do
      work_copy
      |> app_dirs()
      |> Enum.map(&Path.join(Path.relative_to(&1, work_copy), "test"))
    else
      ["test"]
    end
  end

  @doc """
  OTP app names (as strings) for every umbrella child app, read from each
  app's project `:app`. `[]` for single-app projects.
  """
  @spec app_names(Path.t()) :: [String.t()]
  def app_names(work_copy) do
    work_copy
    |> app_dirs()
    |> Enum.map(&app_name/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The umbrella's apps-directory NAME — the configured `:apps_path` (e.g.
  `"packages"`) or `"apps"` when unset/single-app. Call sites that parse an
  `<apps_path>/<app>/...` mutant or source path must use this rather than the
  literal `"apps"`, or a custom `:apps_path` resolves the wrong app.
  """
  @spec apps_path_name(Path.t()) :: String.t()
  def apps_path_name(work_copy) do
    case root_project_ast(work_copy) do
      {:ok, ast} -> apps_path_value(ast) || @default_apps_path
      :error -> @default_apps_path
    end
  end

  @doc """
  Maps each umbrella child's DIRECTORY basename to its OTP `:app` name.

  The two differ whenever a child app is checked out under a directory named
  differently from its application (`apps/web-ui/mix.exs` with `app: :web_ui`,
  `apps/backoffice` with `app: :bo`). Source paths are always
  `<apps_path>/<dir>/lib/...` while Mix writes build artefacts to
  `_build/<env>/lib/<otp_app>/`, so every call site that crosses between the
  two MUST translate through this map rather than reusing a path segment.

  `%{}` for single-app projects and for children whose `:app` cannot be read.
  """
  @spec app_map(Path.t()) :: %{String.t() => String.t()}
  def app_map(work_copy) do
    work_copy
    |> app_dirs()
    |> Enum.flat_map(fn dir ->
      case app_name(dir) do
        nil -> []
        app -> [{Path.basename(dir), app}]
      end
    end)
    |> Map.new()
  end

  @typedoc """
  Pre-resolved umbrella context: the apps-directory name plus the
  directory->OTP-app map. Build it once with `app_context/1` when resolving
  many files, or pass a work copy path and let `otp_app_for_file/2` do it.
  """
  @type app_context :: {String.t(), %{String.t() => String.t()}}

  @doc "The `{apps_path_name, app_map}` pair for a work copy."
  @spec app_context(Path.t()) :: app_context()
  def app_context(work_copy), do: {apps_path_name(work_copy), app_map(work_copy)}

  @doc """
  The OTP app name owning `file`, or `nil` when the file is not under a known
  umbrella child.

  `file` may be work-copy-relative or absolute: the `<apps_path>/<dir>`
  segment pair is located anywhere in the path. The first argument is either a
  work copy path or a pre-built `app_context/1` pair.
  """
  @spec otp_app_for_file(Path.t() | app_context(), Path.t()) :: String.t() | nil
  def otp_app_for_file(work_copy, file) when is_binary(work_copy),
    do: otp_app_for_file(app_context(work_copy), file)

  def otp_app_for_file({apps_path, map}, file) when is_binary(apps_path) and is_map(map) do
    case file |> Path.split() |> Enum.drop_while(&(&1 != apps_path)) do
      [^apps_path, dir | _rest] -> Map.get(map, dir)
      _other -> nil
    end
  end

  @doc "The `:app` atom of a single app dir, as a string, or `nil`."
  @spec app_name(Path.t()) :: String.t() | nil
  def app_name(app_dir) do
    case project_ast(user_mix_path(app_dir)) do
      {:ok, ast} -> app_from_ast(ast)
      :error -> nil
    end
  end

  @doc """
  The OTP app name (as a string) from a mix.exs AST, or `nil`.

  Reads the `:app` entry of the keyword list returned by the project's
  `project/0`. The value may be an atom literal (`app: :my_app`) or a
  module-attribute read (`app: @app`, with `@app :my_app` defined earlier in
  the file) — the common idiom that the previous 3-tuple clause mis-matched as
  the attribute-read node `{:app, _, nil}` and returned the string `"nil"`
  (R1).

  T21: the lookup is STRUCTURAL — it locates the `def project` clause and
  reads the `:app` key of the keyword list it returns. A blind AST walk
  accepted the first `{:app, atom}` pair anywhere in the file, so an `app:
  false` inside a dep (or any unrelated keyword with an `:app` key) declared
  before `project/0` won the race and named the app `"false"`.
  """
  @spec app_from_ast(Macro.t()) :: String.t() | nil
  def app_from_ast(ast) do
    attrs = collect_attr_literals(ast)

    case project_keyword_lists(ast) do
      [] -> nil
      lists -> Enum.find_value(lists, &app_from_keyword(&1, attrs))
    end
  end

  # `app: :my_app` / `app: @app`, read only from the project keyword list.
  defp app_from_keyword(list, attrs) do
    Enum.find_value(list, fn
      {:app, value} when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      {:app, {:@, _, [{attr, _, ctx}]}} when is_atom(attr) and (is_nil(ctx) or is_atom(ctx)) ->
        case Map.fetch(attrs, attr) do
          {:ok, value} when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
          _ -> nil
        end

      _entry ->
        nil
    end)
  end

  # Candidate keyword lists returned by `def project` (arity 0). `nil` args is
  # the `def project` (no parens) form; `[]` is `def project()`.
  defp project_keyword_lists(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:project, _, args}, body]} = node, acc when args in [nil, []] ->
          {node, acc ++ return_keyword_lists(body_expr(body))}

        node, acc ->
          {node, acc}
      end)

    clauses
  end

  defp body_expr([{{:__block__, _, [:do]}, expr} | _rest]), do: expr
  defp body_expr([{:do, expr} | _rest]), do: expr
  defp body_expr(_body), do: nil

  # The keyword list(s) a `project/0` body can evaluate to: a literal list, the
  # last expression of a block, or either side of a `++` concatenation
  # (`[app: :x] ++ shared()`). Anything else (a bare helper call) yields none.
  defp return_keyword_lists({:__block__, _, exprs}) when exprs != [],
    do: exprs |> List.last() |> return_keyword_lists()

  defp return_keyword_lists({:++, _, [left, right]}),
    do: return_keyword_lists(left) ++ return_keyword_lists(right)

  defp return_keyword_lists(list) when is_list(list), do: [list]
  defp return_keyword_lists(_expr), do: []

  # Module-attribute definitions with an atom/string literal value:
  # `@app :my_app`, `@apps_path "packages"`.
  # The definition node is `{:@, _, [{name, _, [value]}]}` (arg list); the
  # *read* node `{:@, _, [{name, _, nil}]}` carries `nil` not a list, so it
  # never matches here.
  defp collect_attr_literals(ast) do
    {_ast, map} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc
        when is_atom(name) and (is_atom(value) or is_binary(value)) ->
          # `Map.put` (not `put_new`): a re-defined attribute resolves to its
          # LAST value, matching Elixir's last-write-wins attribute semantics.
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    map
  end

  defp apps_path_glob(apps_dir), do: Path.join([apps_dir, "*"])

  # T20: `<apps_path>/*` also matches stray files (a README, a build artifact,
  # an editor scratch file) and directories that are not Mix projects. Those
  # used to reach the overlay installer, which aborted the whole run with
  # `:not_a_mix_project`; they also polluted app names, test dirs and source
  # globs. A child app is a DIRECTORY carrying a `mix.exs` — or the overlay's
  # renamed `mix_user.exs`, so the predicate keeps holding after installation.
  defp mix_project_dir?(dir) do
    File.dir?(dir) and
      (File.regular?(Path.join(dir, "mix.exs")) or
         File.regular?(Path.join(dir, "mix_user.exs")))
  end

  defp root_project_ast(work_copy), do: project_ast(user_mix_path(work_copy))

  defp project_ast(path) do
    if File.exists?(path) do
      {:ok, path |> File.read!() |> Code.string_to_quoted!()}
    else
      :error
    end
  end

  # Prefers mix_user.exs (the renamed original) when the overlay is installed.
  defp user_mix_path(dir) do
    user = Path.join(dir, "mix_user.exs")
    if File.exists?(user), do: user, else: Path.join(dir, "mix.exs")
  end

  defp apps_path_value(ast) do
    attrs = collect_attr_literals(ast)

    {_ast, value} =
      Macro.prewalk(ast, nil, fn
        {:apps_path, path} = node, nil ->
          {node, resolve_apps_path_value(path, attrs)}

        list, nil when is_list(list) ->
          {list, resolve_apps_path_value(Keyword.get(list, :apps_path), attrs)}

        node, acc ->
          {node, acc}
      end)

    value
  end

  defp resolve_apps_path_value(path, _attrs) when is_binary(path), do: path

  defp resolve_apps_path_value({:@, _, [{attr, _, ctx}]}, attrs)
       when is_atom(attr) and (is_nil(ctx) or is_atom(ctx)) do
    case Map.fetch(attrs, attr) do
      {:ok, path} when is_binary(path) -> path
      _ -> nil
    end
  end

  defp resolve_apps_path_value(_path, _attrs), do: nil
end
