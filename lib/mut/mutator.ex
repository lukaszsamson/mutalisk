defmodule Mut.Mutator do
  @moduledoc "Behaviour for mutation generators."

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback targets() :: [
              :dispatch
              | :guard
              | :module_attribute
              | :body_literal
              | :env_walker
              | :pattern_literal
              | :variable
              | :pattern_shape
              | :conditional
              | :statement_delete
              | :clause_delete
              | :guard_boolean
              | :pipeline_drop
              | :map_update_drop
              | :receive_timeout
            ]
  @callback applicable?(Macro.t(), Mut.Context.t()) :: boolean()
  @callback mutate(Macro.t(), Mut.Context.t()) :: [Mut.Mutation.t()]
  @callback equivalent?(Mut.Mutation.t()) :: boolean()
end
