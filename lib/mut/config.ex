defmodule Mut.Config do
  @moduledoc """
  Resolves the effective `mix mut` configuration by layering, lowest to
  highest precedence:

      `.mutalisk.exs` project file  <  `config :mut`  <  CLI flags

  This module produces the merged `.mutalisk.exs` + `config :mut` keyword list;
  `Mut.Cli.parse/2` layers CLI flags on top (a CLI flag always wins over both).

  `.mutalisk.exs` lives in the project root (the cwd of `mix mut`) and must
  evaluate to a keyword list of the same keys accepted under `config :mut`,
  e.g.:

      # .mutalisk.exs
      [
        selection: :coverage_with_static_fallback,
        fail_at: 75.0,
        concurrency: 8,
        enabled_targets: [:dispatch, :guard],
        exclude: [~r"lib/my_app_web/router.ex"]
      ]

  Keeping the file as a plain keyword-list term (not `Config.config/2`) means it
  needs no `Config` runtime and is trivially mergeable with `config :mut`.
  """

  @config_file ".mutalisk.exs"

  @doc """
  The effective `.mutalisk.exs` + `config :mut` keyword list (file entries
  overridden by `config :mut`). CLI flags are layered on later by
  `Mut.Cli.parse/2`.
  """
  @spec load(root :: Path.t()) :: keyword()
  def load(root \\ File.cwd!()) do
    file_config = load_file(Path.join(root, @config_file))
    app_config = Application.get_all_env(:mut)
    # `config :mut` (app) overrides the file; CLI overrides both (in Cli.parse).
    Keyword.merge(file_config, app_config)
  end

  @doc "Name of the project-level config file."
  @spec config_file() :: String.t()
  def config_file, do: @config_file

  defp load_file(path) do
    if File.exists?(path) do
      try do
        {term, _bindings} = Code.eval_file(path)
        validate(term)
      rescue
        # Parse- and compile-class failures from the user's config file. Both
        # TokenMissingError and MismatchedDelimiterError (Elixir 1.17+) cover the
        # common "unclosed bracket/heredoc/paren" typos and do NOT inherit from
        # SyntaxError, so they must be listed explicitly. Use Exception.message/1
        # rather than `e.message`: CompileError has no :message key (only
        # :description/:line/:file) and `e.message` would raise a confusing
        # KeyError over the friendly error we are trying to produce.
        e in [CompileError, SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
          Mix.raise("invalid #{path}:\n#{Exception.message(e)}")
      end
    else
      []
    end
  end

  defp validate(term) when is_list(term) do
    if Keyword.keyword?(term), do: term, else: raise_invalid(term)
  end

  defp validate(term), do: raise_invalid(term)

  @spec raise_invalid(term()) :: no_return()
  defp raise_invalid(term) do
    Mix.raise("#{@config_file} is invalid: expected a keyword list, got: #{inspect(term)}")
  end
end
