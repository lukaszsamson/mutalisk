defmodule Mut.TextTest do
  use ExUnit.Case, async: true

  @moduledoc "T24: invalid UTF-8 in child output must never reach the JSON encoder."

  alias Mut.Text

  test "valid UTF-8 is returned unchanged" do
    for input <- ["", "plain ascii", "ünïcodé ✓ 🎯", "line\nline\t\0"] do
      assert Text.scrub_utf8(input) == input
    end
  end

  test "invalid bytes become U+FFFD and the surrounding text survives" do
    assert Text.scrub_utf8(<<255, 254, "ok">>) == "��ok"
    assert Text.scrub_utf8(<<"before ", 0xC3, " after">>) == "before � after"
    assert Text.scrub_utf8(<<0xE2, 0x9C>>) == "��"
  end

  test "the scrubbed result is accepted by the JSON encoder" do
    scrubbed = Text.scrub_utf8(<<255, 254, "ok">>)

    assert String.valid?(scrubbed)
    assert {:ok, encoded} = Mut.JSON.encode(%{"raw_output" => scrubbed})
    assert Mut.JSON.decode!(encoded) == %{"raw_output" => scrubbed}
  end

  test "raw invalid bytes are what the encoder would reject" do
    assert {:error, _exception} = Mut.JSON.encode(%{"raw_output" => <<255, 254, "ok">>})
  end

  test "multi-byte codepoints adjacent to invalid bytes are preserved" do
    assert Text.scrub_utf8(<<"é", 255, "é">>) == "é�é"
  end
end
