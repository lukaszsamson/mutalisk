defmodule Mut.SourcePatch do
  @moduledoc "Fallback byte-range source patch."

  @derive Jason.Encoder
  @enforce_keys [
    :file,
    :start_byte,
    :end_byte,
    :start_line,
    :original,
    :replacement
  ]
  defstruct [
    :file,
    :start_byte,
    :end_byte,
    :start_line,
    :start_column,
    :end_line,
    :end_column,
    :original,
    :replacement
  ]

  @type t :: %__MODULE__{
          file: Path.t(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          start_line: pos_integer(),
          start_column: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          original: String.t(),
          replacement: String.t()
        }
end
