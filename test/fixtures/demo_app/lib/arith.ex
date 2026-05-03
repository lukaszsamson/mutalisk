defmodule Arith do
  @moduledoc "Fixture arithmetic module."

  def score(a, b) do
    (a + b) * (a - b)
  end

  def integer_parts(a, b) do
    {div(a, b), rem(a, b)}
  end
end
