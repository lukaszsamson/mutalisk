defmodule Cmp do
  @moduledoc "Fixture comparison module."

  def ordered?(a, b) do
    a <= b
  end

  def distinct_direction?(a, b) do
    a > b or a >= b or a == b or a != b
  end
end
