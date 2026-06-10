defmodule Mut.SourceSpan.ComputeLiteralSpanTest do
  use ExUnit.Case, async: true

  @moduledoc """
  R3 regression: `literal_span/5` must cover the COMPLETE literal so a
  fallback splice replaces the whole token, not a corrupt prefix
  (`:ok` was spanned as `:o`, `nil` as zero bytes).
  """

  alias Mut.SourceSpan.Compute

  # Parse `expr` with the same options the schema literal walker uses, find the
  # marked literal block carrying `value`, compute its span, and return the
  # exact source bytes the span covers.
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

  test "atom literal spans the full `:ok` (was `:o`)" do
    assert spanned_bytes("def f(x), do: x == :ok\n", :ok) == ":ok"
  end

  test "nil spans the full word (was zero bytes)" do
    assert spanned_bytes("def f, do: nil\n", nil) == "nil"
  end

  test "true/false span the full word" do
    assert spanned_bytes("def f, do: true\n", true) == "true"
  end

  test "string literal spans through the closing quote" do
    assert spanned_bytes(~s|def f, do: "hello"\n|, "hello") == ~s|"hello"|
  end

  test "integer literal spans its digits" do
    assert spanned_bytes("def f, do: 42\n", 42) == "42"
  end
end
