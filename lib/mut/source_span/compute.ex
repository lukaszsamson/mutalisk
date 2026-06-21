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

  @doc """
  Span covering a COMPLETE scalar literal (M46). The pre-M46 logic computed
  `end_column = column + String.length(token)`, which spanned `:ok` as `":o"`
  and `nil` as zero bytes — when rerouted to fallback that corrupt byte range
  spliced `x == :ok` into `x == :errork` (R3). The end is instead derived from
  the literal's actual source shape:

    * `:token` (numbers) — the recorded token text length.
    * `:delimiter` (strings, quoted atoms) — scan to the matching close,
      honoring `\\`-escapes.
    * bare atom / `nil` / `true` / `false` — `:` prefix (none for the bare
      words) plus the atom text.
    * otherwise — a conservative 1-byte span.

  This is the single source of truth shared with `Mut.EnvWalker`'s literal
  path; the schema literal walker (`Mut.AstWalk`) routes through here too.
  """
  @spec literal_span(keyword, term, String.t() | nil, Path.t(), line_offsets) ::
          SourceSpan.t() | nil
  def literal_span(_meta, _value, nil, _file, _line_offsets), do: nil

  def literal_span(meta, value, source, file, line_offsets) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if is_integer(line) and is_integer(column) do
      start_byte = byte_offset(source, line_offsets, line, column)
      end_byte = literal_end_byte(source, start_byte, meta, value)
      {end_line, end_column} = byte_to_line_col(line_offsets, end_byte)

      %SourceSpan{
        file: file,
        start_line: line,
        start_column: column,
        end_line: end_line,
        end_column: end_column,
        start_byte: start_byte,
        end_byte: end_byte
      }
    end
  end

  # Shared with `Mut.EnvWalker` (the literal-span byte scan is identical in both
  # span paths). Pure over `(source, start_byte, ...)` — no dependency on the
  # caller's line-offset representation — so it lives here once.
  @doc false
  def literal_end_byte(source, start_byte, meta, value) do
    cond do
      token = Keyword.get(meta, :token) ->
        start_byte + byte_size(to_string(token))

      delimiter = Keyword.get(meta, :delimiter) ->
        # A quoted atom (`:"a b"`) carries BOTH a `:delimiter` and an atom value;
        # its literal begins with a `:` *before* the opening delimiter, so skip
        # that byte before scanning for the close (else the scan starts on the
        # `:`, matches the opening quote as the close, and yields a corrupt `:"`).
        # Key off the actual source byte rather than `is_atom(value)`: a quoted
        # keyword key (`"a b": 1`) is also an atom but its column points at the
        # opening quote, not a `:`, so a byte-check is correct in every case.
        atom_prefix = if has_atom_colon?(source, start_byte), do: 1, else: 0
        scan_delimited_end(source, start_byte + atom_prefix, delimiter)

      is_atom(value) ->
        prefix = if value in [nil, true, false], do: 0, else: 1
        start_byte + prefix + byte_size(Atom.to_string(value))

      true ->
        start_byte + 1
    end
  end

  defp has_atom_colon?(source, start_byte) do
    start_byte < byte_size(source) and binary_part(source, start_byte, 1) == ":"
  end

  @doc false
  def scan_delimited_end(source, start_byte, delimiter) do
    dsize = byte_size(delimiter)

    # A non-interpolated heredoc literal (`"""..."""` / `'''...'''`) is a bare
    # binary too, so it reaches this scanner with a 3-byte `:delimiter` (the
    # parser records the triple-quote). Heredocs have DIFFERENT close
    # semantics than a single-quote string: the closing triple-quote must sit
    # on its own line (only indentation before it), and a mid-line `"""` in the
    # body does NOT close. Scanning byte-for-byte for the next `"""` (the
    # single-line rule) would match such an interior triple-quote and truncate
    # the span. Interpolated heredocs (`{:<<>>, ...}`) and `~S"""`-style sigils
    # (call nodes) never reach here, so only the literal-heredoc case matters.
    if heredoc_delimiter?(delimiter) do
      scan_heredoc_close(source, start_byte + dsize, delimiter, dsize)
    else
      scan_delimiter_close(source, start_byte + dsize, delimiter, dsize)
    end
  end

  defp heredoc_delimiter?(delimiter), do: delimiter in ["\"\"\"", "'''"]

  defp scan_delimiter_close(source, pos, delimiter, dsize) do
    cond do
      pos + dsize > byte_size(source) ->
        byte_size(source)

      binary_part(source, pos, dsize) == delimiter ->
        pos + dsize

      binary_part(source, pos, 1) == "\\" ->
        scan_delimiter_close(source, pos + 2, delimiter, dsize)

      true ->
        scan_delimiter_close(source, pos + 1, delimiter, dsize)
    end
  end

  # Heredoc close: the terminating triple-quote is only recognized when it
  # begins a line (after the opening triple-quote, content starts on the NEXT
  # line). We track `at_line_start?` — true right after a newline and while only
  # spaces/tabs (the indentation) have followed it — and accept the delimiter
  # only at such a position. `\\`-escapes still skip a byte pair (heredoc bodies
  # honor escapes), which also prevents an escaped char from spuriously
  # resetting the line-start flag.
  defp scan_heredoc_close(source, pos, delimiter, dsize, at_line_start? \\ false) do
    cond do
      pos + dsize > byte_size(source) ->
        byte_size(source)

      at_line_start? and binary_part(source, pos, dsize) == delimiter ->
        pos + dsize

      binary_part(source, pos, 1) == "\\" ->
        # A `\`-escape skips the escaped byte too. But a `\`-newline is a line
        # continuation: the escaped newline still ends the line, so the closing
        # delimiter on the NEXT line must remain recognizable. Clearing
        # `at_line_start?` unconditionally here would overshoot the span to EOF
        # when a body line ends in `\` right before the closing fence.
        next_at_line_start? = binary_part(source, pos + 1, 1) == "\n"
        scan_heredoc_close(source, pos + 2, delimiter, dsize, next_at_line_start?)

      binary_part(source, pos, 1) == "\n" ->
        scan_heredoc_close(source, pos + 1, delimiter, dsize, true)

      at_line_start? and binary_part(source, pos, 1) in [" ", "\t"] ->
        scan_heredoc_close(source, pos + 1, delimiter, dsize, true)

      true ->
        scan_heredoc_close(source, pos + 1, delimiter, dsize, false)
    end
  end

  # Map representation: line_number => starting byte offset. Find the line whose
  # offset is the greatest not exceeding `byte`. `line_offsets` is an UNSORTED
  # map (no ordering to exploit), so this is unavoidably O(lines); a single
  # `reduce` replaces the prior `filter |> max_by` two-pass with no intermediate
  # list. Provably equivalent: per-line offsets are strictly increasing in
  # `line_offsets/1`, so they are unique — there are no ties for `max_by` to
  # disambiguate — and the seed `{1, 0}` reproduces the old `max_by` default
  # (it can only win when no offset `<= byte`, i.e. byte < 0, which never
  # happens since line 1's offset is 0 and `byte >= 0`).
  defp byte_to_line_col(line_offsets, byte) do
    {line, offset} =
      Enum.reduce(line_offsets, {1, 0}, fn
        {l, off}, {_bl, boff} when off <= byte and off > boff -> {l, off}
        _entry, best -> best
      end)

    {line, byte - offset + 1}
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
