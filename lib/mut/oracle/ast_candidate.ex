defmodule Mut.Oracle.AstCandidate do
  @moduledoc "Source AST candidate for oracle matching."

  @enforce_keys [
    :file,
    :line,
    :syntactic_name,
    :syntactic_arity,
    :ast_path,
    :ast_path_hash,
    :node
  ]
  defstruct [
    :file,
    :line,
    :column,
    :syntactic_name,
    :syntactic_arity,
    :source_span,
    :env_context,
    :enclosing_module,
    :ast_path,
    :ast_path_hash,
    :node,
    # M54: in-scope variable names at this node (params + enclosing clause-head
    # bindings), for the VariableReplace mutator. `nil` for non-variable
    # candidates; never enters stable-id identity.
    :bound_vars
  ]

  @type t :: %__MODULE__{
          file: Path.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          syntactic_name: atom(),
          syntactic_arity: non_neg_integer(),
          source_span: Mut.SourceSpan.t() | nil,
          env_context: nil | :guard | :match,
          enclosing_module: module() | nil,
          ast_path: [term()],
          ast_path_hash: binary(),
          node: Macro.t(),
          bound_vars: [atom()] | nil
        }
end
