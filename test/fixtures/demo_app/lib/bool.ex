defmodule Bool do
  @moduledoc "Fixture boolean module."

  def strict?(a, b) do
    a and not b
  end

  def loose?(a, b) do
    a || b || !b
  end
end
