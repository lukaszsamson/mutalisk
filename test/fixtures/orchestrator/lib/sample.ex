defmodule Sample do
  @moduledoc false

  @some_const 42

  def f(x) when x > 0 do
    x + @some_const
  end
end
