defmodule Mut.FallbackPatch do
  @moduledoc "Renders and applies fallback source patches."

  alias Mut.Mutant
  alias Mut.SourcePatch

  @spec render(Mutant.t(), String.t()) :: {:ok, SourcePatch.t()} | {:error, :missing_source_span}
  def render(%Mutant{start_byte: nil}, _source_text), do: {:error, :missing_source_span}
  def render(%Mutant{end_byte: nil}, _source_text), do: {:error, :missing_source_span}

  def render(%Mutant{} = mutant, source_text) when is_binary(source_text) do
    original = binary_part(source_text, mutant.start_byte, mutant.end_byte - mutant.start_byte)
    replacement = operator_only_replacement(mutant, original) || rendered_replacement(mutant)

    {:ok,
     %SourcePatch{
       file: mutant.file,
       start_byte: mutant.start_byte,
       end_byte: mutant.end_byte,
       start_line: mutant.line,
       start_column: mutant.column,
       end_line: end_line(mutant),
       end_column: end_column(mutant),
       original: original,
       replacement: replacement
     }}
  end

  defp rendered_replacement(mutant) do
    mutant.mutated_ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
  end

  # When the span covers ONLY the operator token (set by `Mut.AstWalk`'s
  # `operator_token_span/3` because operand-literal normalisation defeated the
  # whole-expression text search), substitute just the new operator. This keeps
  # operand literals (`0x7FF`, `10_000`, `?a`) verbatim instead of rendering the
  # whole node. Recognised when the mutation is a pure operator swap (same
  # operands) and the original bytes equal the original operator.
  defp operator_only_replacement(
         %Mutant{original_ast: {op1, _m1, args1}, mutated_ast: {op2, _m2, args2}},
         original
       )
       when is_atom(op1) and is_atom(op2) and is_list(args1) and is_list(args2) and
              length(args1) == length(args2) do
    if args1 == args2 and original == Atom.to_string(op1) do
      Atom.to_string(op2)
    end
  end

  defp operator_only_replacement(_mutant, _original), do: nil

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
