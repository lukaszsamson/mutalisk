defmodule BoolTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # M8 expects one boolean mutant to survive and the rest to be classified.
  test "strict? requires true and not false" do
    assert Bool.strict?(true, false) == true
    assert Bool.strict?(false, false) == false
  end

  test "loose? accepts either side" do
    assert Bool.loose?(false, true) == true
  end
end
