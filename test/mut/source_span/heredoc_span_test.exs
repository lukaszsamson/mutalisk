defmodule Mut.SourceSpan.HeredocSpanTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Regression / coverage tests for `literal_span/5` against heredoc string
  literals.

  A non-interpolated heredoc (`\"\"\"..."\""`) is a bare binary literal that
  carries `:delimiter` = `"\"\"\""` in its parser metadata, so it reaches
  `scan_delimited_end`. The scanner must walk past all content (including
  embedded newlines and an interior `"`/`\"""`-mid-line) and land exactly on the
  byte AFTER the closing fence — no under- or over-shoot (R3).

  Sigils (`~s\"""`, `~S(...)`, `~c'''`) parse to call nodes and interpolated
  heredocs parse to `{:<<>>, ...}` — neither is a bare binary, so neither
  reaches `literal_span`/`scan_delimited_end`. They are intentionally NOT
  covered here (a `literal_encoder` round-trip never wraps them as standalone
  literals). See `Mut.SourceSpan.Compute.scan_delimited_end/3`.

  Tests use the same `literal_encoder` round-trip as
  `Mut.SourceSpan.ComputeLiteralSpanTest` so they exercise the production path
  through `Compute.literal_span/5`.
  """

  alias Mut.SourceSpan.Compute

  # Parse `source`, locate the __block__-wrapped literal whose value equals
  # `value`, compute its span, and return the raw bytes the span covers.
  # Mirrors the helper in ComputeLiteralSpanTest (established style).
  defp spanned_bytes(source, value) do
    line_offsets = Compute.line_offsets(source)

    {:ok, ast} =
      Code.string_to_quoted(source,
        columns: true,
        token_metadata: true,
        literal_encoder: fn lit, meta -> {:ok, {:__block__, meta, [lit]}} end
      )

    {_ast, span} =
      Macro.prewalk(ast, nil, fn
        {:__block__, meta, [^value]} = node, nil ->
          {node, Compute.literal_span(meta, value, source, "lib/x.ex", line_offsets)}

        node, acc ->
          {node, acc}
      end)

    refute is_nil(span), "no span computed for #{inspect(value)}"
    binary_part(source, span.start_byte, span.end_byte - span.start_byte)
  end

  # ── heredoc tests ──────────────────────────────────────────────────────────

  test "double-quote heredoc span covers opening and closing delimiter" do
    # The literal value is the string between the delimiters (no leading newline
    # captured in the value, but the span must include both `"""` fences).
    source = ~S'''
    def f do
      """
      hello
      """
    end
    '''

    result = spanned_bytes(source, "hello\n")
    assert String.starts_with?(result, ~s("""))
    assert String.ends_with?(result, ~s("""))
    # Span must not over-shoot: nothing after the closing `"""` is included.
    refute result =~ "\nend"
  end

  test "heredoc span covers multiple lines without truncation" do
    source = ~S'''
    def f do
      """
      line one
      line two
      """
    end
    '''

    result = spanned_bytes(source, "line one\nline two\n")
    assert result =~ "line one"
    assert result =~ "line two"
    assert String.ends_with?(result, ~s("""))
  end

  test "heredoc with a double-quote inside is not terminated early" do
    # A `"` inside the body must not fool the scanner into stopping early —
    # only the triple `"""` closes a double-quote heredoc.
    source = ~S'''
    def f do
      """
      say "hi"
      """
    end
    '''

    result = spanned_bytes(source, ~s(say "hi"\n))
    assert result =~ ~s(say "hi")
    assert String.ends_with?(result, ~s("""))
  end

  test "heredoc body line ending in backslash-continuation does not overshoot (R3)" do
    # A `\`-escaped trailing newline is a line continuation; the escaped newline
    # still ends the line, so the closing fence on the NEXT line must still be
    # recognized. A regression here clears the line-start flag and overshoots the
    # span to end-of-file (swallowing `end`). The continuation collapses the body
    # to the value "line".
    source = ~S'''
    def f do
      """
      line\
      """
    end
    '''

    result = spanned_bytes(source, "line")
    assert String.ends_with?(result, ~s("""))
    refute result =~ "\nend"
  end

  # ── span field sanity ──────────────────────────────────────────────────────

  test "heredoc span: start_byte < end_byte and end_byte does not exceed source size" do
    source = ~S'''
    def f do
      """
      content
      """
    end
    '''

    line_offsets = Compute.line_offsets(source)

    {:ok, ast} =
      Code.string_to_quoted(source,
        columns: true,
        token_metadata: true,
        literal_encoder: fn lit, meta -> {:ok, {:__block__, meta, [lit]}} end
      )

    {_ast, span} =
      Macro.prewalk(ast, nil, fn
        {:__block__, meta, ["content\n"]} = node, nil ->
          {node, Compute.literal_span(meta, "content\n", source, "lib/x.ex", line_offsets)}

        node, acc ->
          {node, acc}
      end)

    refute is_nil(span)
    assert span.start_byte < span.end_byte
    assert span.end_byte <= byte_size(source)
    assert span.start_line <= span.end_line
  end
end
