defmodule AttrsTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # M8 expects the answer_offset arithmetic mutant to be killed.
  test "answer_offset adds the module attribute" do
    assert Attrs.answer_offset(8) == 50
    assert Attrs.answer_offset(0) == 42
  end
end
