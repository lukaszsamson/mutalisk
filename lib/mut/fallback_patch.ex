defmodule Mut.FallbackPatch do
  @moduledoc "Renders and applies fallback source patches."

  alias Mut.Mutant
  alias Mut.SourcePatch

  @spec render(Mutant.t(), String.t()) :: {:ok, SourcePatch.t()} | {:error, :missing_source_span}
  def render(%Mutant{start_byte: nil}, _source_text), do: {:error, :missing_source_span}
  def render(%Mutant{end_byte: nil}, _source_text), do: {:error, :missing_source_span}

  def render(%Mutant{} = mutant, source_text) when is_binary(source_text) do
    replacement =
      mutant.mutated_ast
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.iodata_to_binary()
      |> String.trim_trailing("\n")

    {:ok,
     %SourcePatch{
       file: mutant.file,
       start_byte: mutant.start_byte,
       end_byte: mutant.end_byte,
       start_line: mutant.line,
       start_column: mutant.column,
       end_line: end_line(mutant),
       end_column: end_column(mutant),
       original: binary_part(source_text, mutant.start_byte, mutant.end_byte - mutant.start_byte),
       replacement: replacement
     }}
  end

  @spec apply(SourcePatch.t(), Path.t()) :: :ok
  def apply(%SourcePatch{} = patch, sandbox_root) when is_binary(sandbox_root) do
    path = Path.join(sandbox_root, patch.file)
    source = File.read!(path)

    before_bytes = binary_part(source, 0, patch.start_byte)
    after_bytes = binary_part(source, patch.end_byte, byte_size(source) - patch.end_byte)

    File.write!(path, before_bytes <> patch.replacement <> after_bytes)
    :ok
  end

  defp end_line(%Mutant{span: {_start_line, _start_column, end_line, _end_column}}), do: end_line
  defp end_line(_mutant), do: nil

  defp end_column(%Mutant{span: {_start_line, _start_column, _end_line, end_column}}),
    do: end_column

  defp end_column(_mutant), do: nil
end
