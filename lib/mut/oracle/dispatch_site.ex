defmodule Mut.Oracle.DispatchSite do
  @moduledoc "Normalized compiler dispatch site."

  @derive Jason.Encoder
  @enforce_keys [
    :file,
    :line,
    :dispatch_kind,
    :resolved_name,
    :resolved_arity,
    :event_file
  ]
  defstruct [
    :file,
    :line,
    :column,
    :end_line,
    :end_column,
    :env_context,
    :module,
    :function,
    :dispatch_kind,
    :resolved_module,
    :resolved_name,
    :resolved_arity,
    :event_file,
    meta: []
  ]

  @type dispatch_kind ::
          :remote_function
          | :remote_macro
          | :local_function
          | :local_macro
          | :imported_function
          | :imported_macro

  @type t :: %__MODULE__{
          file: Path.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          env_context: nil | :match | :guard,
          module: module() | nil,
          function: {atom(), arity()} | nil,
          dispatch_kind: dispatch_kind(),
          resolved_module: module() | nil,
          resolved_name: atom(),
          resolved_arity: non_neg_integer(),
          event_file: Path.t(),
          meta: keyword()
        }
end
