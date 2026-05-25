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
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
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

  @doc "The `:app` atom of a single app dir, as a string, or `nil`."
  @spec app_name(Path.t()) :: String.t() | nil
  def app_name(app_dir) do
    case project_ast(user_mix_path(app_dir)) do
      {:ok, ast} -> app_from_ast(ast)
      :error -> nil
    end
  end

  defp apps_path_glob(apps_dir), do: Path.join([apps_dir, "*"])

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
    {_ast, value} =
      Macro.prewalk(ast, nil, fn
        {:apps_path, path}, nil when is_binary(path) -> {{:apps_path, path}, path}
        list, nil when is_list(list) -> {list, Keyword.get(list, :apps_path)}
        node, acc -> {node, acc}
      end)

    value
  end

  defp app_from_ast(ast) do
    {_ast, app} =
      Macro.prewalk(ast, nil, fn
        {:app, _meta, value}, nil when is_atom(value) ->
          {{:app, [], value}, Atom.to_string(value)}

        {:app, value}, nil when is_atom(value) ->
          {{:app, value}, Atom.to_string(value)}

        node, app ->
          {node, app}
      end)

    app
  end
end
