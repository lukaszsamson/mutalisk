defmodule Mut.SourceParse do
  @moduledoc "Parses source files with mutation metadata."

  @parser_opts [columns: true, token_metadata: true, emit_warnings: false]

  @spec parse(file :: Path.t()) ::
          {:ok, {Macro.t(), source_text :: String.t()}} | {:error, term}
  def parse(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- parse_string(source, file) do
      {:ok, {ast, source}}
    end
  end

  @spec parse_string(source :: String.t(), file :: Path.t()) :: {:ok, Macro.t()} | {:error, term}
  def parse_string(source, file) do
    case Code.string_to_quoted(source, Keyword.put(@parser_opts, :file, file)) do
      {:ok, ast} -> {:ok, ast}
      {:error, {location, _prefix, message}} -> {:error, parse_error(file, location, message)}
    end
  end

  defp parse_error(file, location, message) do
    {file, Keyword.get(location, :line, 1), to_string(message)}
  end
end
