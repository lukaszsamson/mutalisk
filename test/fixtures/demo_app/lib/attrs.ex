defmodule Attrs do
  @moduledoc "Fixture attributes module."

  @some_const 42

  def answer_offset(offset) do
    @some_const + offset
  end
end
