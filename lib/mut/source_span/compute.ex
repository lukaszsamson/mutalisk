defmodule Mut.SourceSpan.Compute do
  @moduledoc "Computes byte spans from parser metadata."

  alias Mut.SourceSpan

  @type line_offsets :: %{pos_integer() => non_neg_integer()}

  @spec from_meta(meta :: keyword, source :: String.t() | nil, file :: Path.t()) ::
          SourceSpan.t() | nil
  def from_meta(_meta, nil, _file), do: nil

  def from_meta(meta, source, file) do
    from_meta(meta, source, file, line_offsets(source))
  end

  @spec from_meta(keyword, String.t() | nil, Path.t(), line_offsets) :: SourceSpan.t() | nil
  def from_meta(_meta, nil, _file, _line_offsets), do: nil

  def from_meta(meta, source, file, line_offsets) do
    with line when is_integer(line) <- Keyword.get(meta, :line),
         {end_line, end_column} <- end_position(meta) do
      start_column = Keyword.get(meta, :column)

      %SourceSpan{
        file: file,
        start_line: line,
        start_column: start_column,
        end_line: end_line,
        end_column: end_column,
        start_byte: byte_offset(source, line_offsets, line, start_column || 1),
        end_byte: byte_offset(source, line_offsets, end_line, end_column || 1)
      }
    else
      _missing -> nil
    end
  end

  defp end_position(meta) do
    cond do
      is_integer(meta[:end_line]) ->
        {meta[:end_line], meta[:end_column]}

      is_list(meta[:closing]) ->
        {Keyword.fetch!(meta[:closing], :line), Keyword.fetch!(meta[:closing], :column) + 1}

      true ->
        nil
    end
  end

  @spec line_offsets(String.t()) :: line_offsets
  def line_offsets(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, 0}, fn {line, line_number}, {offsets, offset} ->
      {Map.put(offsets, line_number, offset), offset + byte_size(line) + 1}
    end)
    |> elem(0)
  end

  defp byte_offset(source, line_offsets, line, column) do
    line_start = Map.fetch!(line_offsets, line)

    source
    |> binary_part(line_start, byte_size(source) - line_start)
    |> String.split("\n", parts: 2)
    |> hd()
    |> first_codepoints_bytes(column - 1)
    |> Kernel.+(line_start)
  end

  defp first_codepoints_bytes(_line, count) when count <= 0, do: 0

  defp first_codepoints_bytes(line, count) do
    line
    |> String.slice(0, count)
    |> byte_size()
  end
end
