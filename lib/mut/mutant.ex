defmodule Mut.Mutant do
  @moduledoc "Mutation candidate and execution result."

  @derive {Jason.Encoder, except: [:original_ast, :mutated_ast]}
  @enforce_keys [
    :id,
    :stable_id,
    :engine,
    :mutator,
    :mutator_name,
    :file,
    :line,
    :original_ast,
    :mutated_ast,
    :description
  ]
  defstruct [
    :id,
    :stable_id,
    :engine,
    :mutator,
    :mutator_name,
    :file,
    :line,
    :column,
    :span,
    :module,
    :function,
    :original_ast,
    :mutated_ast,
    :source_patch,
    :original_source,
    :mutated_source,
    :description,
    :skip_reason,
    :covering_tests,
    :killing_test,
    :duration_ms,
    :compile_error,
    status: :pending
  ]

  @type engine :: :schema | :fallback
  @type status :: :pending | :killed | :survived | :timeout | :invalid | :skipped | :error

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          stable_id: String.t(),
          engine: engine(),
          mutator: module(),
          mutator_name: String.t(),
          file: Path.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          span:
            {pos_integer(), pos_integer() | nil, pos_integer() | nil, pos_integer() | nil} | nil,
          module: module() | nil,
          function: {atom(), arity()} | nil,
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          source_patch: Mut.SourcePatch.t() | nil,
          original_source: String.t() | nil,
          mutated_source: String.t() | nil,
          description: String.t(),
          status: status(),
          skip_reason: atom() | nil,
          covering_tests: [Path.t()] | nil,
          killing_test: Path.t() | nil,
          duration_ms: non_neg_integer() | nil,
          compile_error: term() | nil
        }
end
