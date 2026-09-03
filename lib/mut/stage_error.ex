defmodule Mut.StageError do
  @moduledoc """
  Human-readable messages for the `{:error, reason}` returns of the pipeline's
  setup stages (oracle build, schema build, sandbox pool creation).

  These stages all have legitimate error returns — an uncompilable project, a
  compile that exceeds the build backstop, a stale artifact directory. They used
  to be pattern-matched as `{:ok, _}` in `mix mut`, so an ordinary user mistake
  surfaced as a bare `MatchError` with a giant `inspect`ed tuple. Every one is
  now turned into a `Mix.raise` carrying this message.
  """

  @type stage :: :oracle_build | :schema_build | :sandbox_pool

  @doc "Message for a failed setup stage."
  @spec message(stage, term) :: String.t()
  def message(stage, reason) do
    "#{label(stage)} failed: #{describe(reason)}"
  end

  defp label(:oracle_build), do: "oracle build"
  defp label(:schema_build), do: "schema build"
  defp label(:sandbox_pool), do: "sandbox pool creation"

  defp describe({:compile_failed, exit_code, output}) do
    "the project did not compile (mix exited #{exit_code})." <> output_tail(output)
  end

  defp describe({:compile_timeout, output}) do
    "the compile exceeded mutalisk's build timeout." <> output_tail(output)
  end

  defp describe({:not_a_mix_project, path}), do: "#{path} is not a Mix project (no mix.exs)"

  defp describe({:already_exists, path}),
    do: "#{path} already exists; remove it and re-run"

  defp describe(:missing_user_project_root), do: "no user project root was supplied (internal)"

  defp describe({exception, message})
       when is_atom(exception) and not is_nil(exception) and is_binary(message) do
    "#{inspect(exception)}: #{message}"
  end

  defp describe(reason), do: inspect(reason)

  defp output_tail(output) when is_binary(output) do
    case String.trim(output) do
      "" -> ""
      tail -> "\n\nLast output:\n#{tail}"
    end
  end

  defp output_tail(other), do: "\n\nLast output:\n#{inspect(other)}"
end
