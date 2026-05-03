defmodule Mut.Mutant do
  @moduledoc "Mutation candidate and execution result."

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
    :mutation_kind,
    :original_dispatch,
    :ast_path_hash,
    :start_byte,
    :end_byte,
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
          mutation_kind: atom() | nil,
          original_dispatch: String.t() | nil,
          ast_path_hash: String.t() | nil,
          start_byte: non_neg_integer() | nil,
          end_byte: non_neg_integer() | nil,
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

defimpl Jason.Encoder, for: Mut.Mutant do
  def encode(mutant, opts) do
    mutant
    |> Map.from_struct()
    |> Map.drop([:original_ast, :mutated_ast])
    |> Map.update!(:span, &encode_span/1)
    |> Map.update!(:function, &encode_function/1)
    |> Jason.Encode.map(opts)
  end

  defp encode_span(nil), do: nil

  defp encode_span({start_line, start_column, end_line, end_column}),
    do: [start_line, start_column, end_line, end_column]

  defp encode_function(nil), do: nil
  defp encode_function({name, arity}), do: [name, arity]
end
