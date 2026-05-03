defmodule DslUserTest do
  use ExUnit.Case, async: true

  @moduledoc false

  # M8 exercises DSL-generated functions while expecting internals to stay skipped.
  test "generated add functions work" do
    assert DslUser.sum(2, 3) == 5
    assert DslUser.sum_keep(2, 3) == 5
  end
end
