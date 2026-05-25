defmodule AppB do
  @moduledoc false

  # Cross-app call: app_b depends on app_a (in_umbrella). Exercises the
  # shared mut build root (AppA must be visible to AppB at compile time).
  def double(n), do: AppA.add(n, n)
end
