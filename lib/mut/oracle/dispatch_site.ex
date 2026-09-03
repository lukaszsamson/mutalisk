defmodule Mut.Oracle.DispatchSite do
  @moduledoc "Normalized compiler dispatch site."

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

defimpl JSON.Encoder, for: Mut.Oracle.DispatchSite do
  def encode(site, encoder) do
    site
    |> Map.from_struct()
    |> Map.update!(:function, &encode_function/1)
    |> Map.update!(:meta, &encode_meta/1)
    |> JSON.protocol_encode(encoder)
  end

  defp encode_function(nil), do: nil
  defp encode_function({name, arity}), do: [name, arity]

  # T41: a bare meta value that happens to be a 2-element list (e.g. `[1, 2]`)
  # is indistinguishable, on the wire, from a `{key, value}` pair encoded as
  # `[key, value]`. Encode pairs as an unambiguous `%{"k" => key, "v" =>
  # value}` map instead so only a real pair round-trips as one; see
  # `Mut.Oracle.decode_meta/1` for the matching (and backward-compatible)
  # decode side.
  defp encode_meta(meta) when is_list(meta) do
    Enum.map(meta, fn
      {key, value} -> %{"k" => key, "v" => value}
      value -> value
    end)
  end
end
