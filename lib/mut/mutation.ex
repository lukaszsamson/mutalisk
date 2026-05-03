defmodule Mut.Mutation do
  @moduledoc "Mutation produced by a mutator."

  @enforce_keys [:original_ast, :mutated_ast, :description, :mutation_kind, :guard_safe?]
  defstruct [
    :original_ast,
    :mutated_ast,
    :description,
    :mutation_kind,
    :guard_safe?,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          description: String.t(),
          mutation_kind: atom(),
          guard_safe?: boolean(),
          metadata: map()
        }
end
