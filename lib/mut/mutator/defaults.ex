defmodule Mut.Mutator.Defaults do
  @moduledoc "Default v1 mutator set."

  @spec list() :: [module]
  def list do
    [
      Mut.Mutator.Arithmetic,
      Mut.Mutator.ComparisonBoundary,
      Mut.Mutator.ComparisonNegation,
      Mut.Mutator.Boolean,
      Mut.Mutator.UnaryNot,
      Mut.Mutator.GuardComparisonBoundary,
      Mut.Mutator.GuardComparisonNegation,
      Mut.Mutator.GuardTypeTest,
      Mut.Mutator.AttributeLiteral,
      Mut.Mutator.IntegerLiteral,
      Mut.Mutator.BooleanLiteral
    ]
  end

  @spec register_all() :: :ok
  def register_all do
    Enum.each(list(), &Mut.Match.Registry.register/1)
  end
end
