defmodule Mut.Context do
  @moduledoc "Mutation context passed to mutators."

  @enforce_keys [:file, :ast_path, :ast_path_hash, :engine]
  defstruct [
    :oracle_site,
    :enclosing_function,
    :enclosing_module,
    :file,
    :source_span,
    :ast_path,
    :ast_path_hash,
    :env_context,
    :engine
  ]

  @type t :: %__MODULE__{
          oracle_site: Mut.Oracle.DispatchSite.t() | nil,
          enclosing_function: {atom(), arity()} | nil,
          enclosing_module: module() | nil,
          file: Path.t(),
          source_span: Mut.SourceSpan.t() | nil,
          ast_path: [term()],
          ast_path_hash: binary(),
          env_context: nil | :match | :guard,
          engine: :schema | :fallback
        }
end
