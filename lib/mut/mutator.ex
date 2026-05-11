defmodule Mut.Mutator do
  @moduledoc "Behaviour for mutation generators."

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback targets() :: [:dispatch | :guard | :module_attribute | :body_literal | :env_walker]
  @callback applicable?(Macro.t(), Mut.Context.t()) :: boolean()
  @callback mutate(Macro.t(), Mut.Context.t()) :: [Mut.Mutation.t()]
  @callback equivalent?(Mut.Mutation.t()) :: boolean()
end
