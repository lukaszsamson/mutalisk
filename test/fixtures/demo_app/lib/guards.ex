defmodule Guards do
  @moduledoc "Fixture guards module."

  def positive?(x) when is_integer(x) and x > 0 do
    true
  end

  def positive?(_x) do
    false
  end
end
