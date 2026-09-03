defmodule Mut.Text do
  @moduledoc """
  Binary/text helpers shared by the capture paths.

  Child processes emit *arbitrary bytes* on stdout/stderr: a mutant can print a
  truncated latin-1 log line, a raw binary payload, or a partial UTF-8 sequence
  cut by an OOM kill. That output is carried in `Mut.Worker.Result.raw_output`
  and copied verbatim into the Stryker JSON report, whose encoder rejects
  invalid UTF-8 — so a single stray byte from any mutant could crash the final
  report write and destroy an hours-long run.

  `scrub_utf8/1` normalises captured output at *capture time*: valid text is
  kept byte-for-byte and each invalid byte becomes U+FFFD, so the result is
  always encodable while remaining readable.
  """

  # U+FFFD REPLACEMENT CHARACTER
  @replacement "�"

  @doc """
  Replace every invalid UTF-8 byte in `binary` with U+FFFD.

  Valid input is returned unchanged (and without copying). Only the offending
  bytes are substituted — the surrounding valid text is preserved.
  """
  @spec scrub_utf8(binary()) :: binary()
  def scrub_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      scrub(binary, [])
    end
  end

  def scrub_utf8(other), do: other

  defp scrub(<<>>, acc), do: IO.iodata_to_binary(acc)

  defp scrub(binary, acc) do
    valid_bytes = valid_prefix(binary, 0)
    acc = if valid_bytes > 0, do: [acc, binary_part(binary, 0, valid_bytes)], else: acc

    case binary_part(binary, valid_bytes, byte_size(binary) - valid_bytes) do
      <<>> -> IO.iodata_to_binary(acc)
      <<_invalid, rest::binary>> -> scrub(rest, [acc, @replacement])
    end
  end

  # Byte length of the longest valid UTF-8 prefix of `binary`.
  defp valid_prefix(<<codepoint::utf8, rest::binary>>, count),
    do: valid_prefix(rest, count + codepoint_size(codepoint))

  defp valid_prefix(_binary, count), do: count

  defp codepoint_size(codepoint) when codepoint <= 0x7F, do: 1
  defp codepoint_size(codepoint) when codepoint <= 0x7FF, do: 2
  defp codepoint_size(codepoint) when codepoint <= 0xFFFF, do: 3
  defp codepoint_size(_codepoint), do: 4
end
