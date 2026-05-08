defmodule Literals do
  @moduledoc """
  M23 fixture: function-body literals for IntegerLiteral and
  BooleanLiteral mutators. Tests pin the values; mutating any of
  them should kill the mutant.
  """

  def magic, do: 42

  def origin, do: 0

  def feature_enabled?, do: true
end
