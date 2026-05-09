defmodule Mut.SourceSpan do
  @moduledoc "Source byte and line span."

  @derive JSON.Encoder
  @enforce_keys [:file, :start_line, :start_byte, :end_byte]
  defstruct [
    :file,
    :start_line,
    :start_column,
    :end_line,
    :end_column,
    :start_byte,
    :end_byte
  ]

  @type t :: %__MODULE__{
          file: Path.t(),
          start_line: pos_integer(),
          start_column: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer()
        }
end
