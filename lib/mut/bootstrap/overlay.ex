defmodule Mut.Bootstrap.Overlay do
  @moduledoc "Generates the working-copy mix.exs overlay."

  @type role :: :oracle | :schema

  @spec materialize(Path.t(), role) :: no_return
  def materialize(_work_copy, _role) do
    raise RuntimeError, "not yet implemented (M2)"
  end

  @spec render(role) :: no_return
  def render(_role) do
    raise RuntimeError, "not yet implemented (M2)"
  end

  @spec assert_not_umbrella!(Path.t()) :: no_return
  def assert_not_umbrella!(_work_copy) do
    raise RuntimeError, "not yet implemented (M2)"
  end
end
