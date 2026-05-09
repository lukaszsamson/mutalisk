defmodule Mut.JSON.OrderedObject do
  @moduledoc """
  Replacement for `Jason.OrderedObject` — a JSON object whose key order is
  preserved on encoding.

  Build with a keyword list or a list of `{key, value}` pairs:

      Mut.JSON.OrderedObject.new(file: "foo.ex", line: 12, column: 3)

  Encodes as a plain JSON object emitting keys in the given order, both via
  `Mut.JSON.encode!/1` (compact and pretty) and `JSON.encode!/1` (compact only).
  """

  @enforce_keys [:entries]
  defstruct [:entries]

  @type entry :: {atom() | String.t(), term()}
  @type t :: %__MODULE__{entries: [entry()]}

  @spec new(Enumerable.t()) :: t()
  def new(entries) do
    %__MODULE__{entries: Enum.to_list(entries)}
  end
end

defimpl JSON.Encoder, for: Mut.JSON.OrderedObject do
  def encode(%Mut.JSON.OrderedObject{entries: []}, _encoder), do: "{}"

  def encode(%Mut.JSON.OrderedObject{entries: entries}, encoder) do
    pairs =
      entries
      |> Enum.map(fn {key, value} ->
        [JSON.encode!(to_string(key)), ?:, encoder.(value, encoder)]
      end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end
end

defmodule Mut.JSON do
  @moduledoc """
  Thin wrapper around Elixir 1.18+ `JSON` module that adds:

    * `pretty: true` option for `encode!/2`, matching the shape of Jason's
      pretty-printed output (2-space indent, sorted map keys, one entry/element
      per line).
    * `Mut.JSON.OrderedObject` for emitting objects with a caller-controlled
      key order (used by golden output that needs deterministic field order).

  All other calls forward to `JSON`. Decoding mirrors Elixir's `JSON` API:

      Mut.JSON.encode!(term)
      Mut.JSON.encode!(term, pretty: true)
      Mut.JSON.decode!(binary)
      Mut.JSON.decode(binary)         # {:ok, term} | {:error, reason}
      Mut.JSON.encode(term)           # {:ok, binary} | {:error, exception}

  ## Notes on differences from Jason

    * `JSON.Encoder` (not `Jason.Encoder`) is the protocol Mutalisk derives.
    * `JSON.encode!/2` in Elixir takes an encoder *function* as its second
      argument, not options. We accept `pretty: true` here and post-process.
    * Pretty output sorts map keys alphabetically for stable goldens. To
      preserve insertion order, wrap the value in `Mut.JSON.OrderedObject.new/1`.
  """

  @typep encode_opt :: {:pretty, boolean()}

  @spec encode!(term()) :: binary()
  def encode!(term), do: JSON.encode!(term)

  @spec encode!(term(), [encode_opt()]) :: binary()
  def encode!(term, opts) when is_list(opts) do
    if Keyword.get(opts, :pretty, false) do
      pretty_encode(term)
    else
      JSON.encode!(term)
    end
  end

  @spec encode(term()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term) do
    {:ok, JSON.encode!(term)}
  rescue
    e -> {:error, e}
  end

  @spec decode!(binary()) :: term()
  def decode!(binary), do: JSON.decode!(binary)

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary), do: JSON.decode(binary)

  # ----------------------------------------------------------------------------
  # Pretty printer
  # ----------------------------------------------------------------------------

  @indent "  "

  defp pretty_encode(term) do
    term
    |> pretty(0)
    |> IO.iodata_to_binary()
  end

  defp pretty(nil, _depth), do: "null"
  defp pretty(true, _depth), do: "true"
  defp pretty(false, _depth), do: "false"
  defp pretty(value, _depth) when is_atom(value), do: JSON.encode!(Atom.to_string(value))
  defp pretty(value, _depth) when is_integer(value), do: Integer.to_string(value)
  defp pretty(value, _depth) when is_float(value), do: JSON.encode!(value)
  defp pretty(value, _depth) when is_binary(value), do: JSON.encode!(value)
  defp pretty([], _depth), do: "[]"

  defp pretty(list, depth) when is_list(list) do
    inner_pad = String.duplicate(@indent, depth + 1)
    outer_pad = String.duplicate(@indent, depth)

    items =
      list
      |> Enum.map(&[inner_pad, pretty(&1, depth + 1)])
      |> Enum.intersperse(",\n")

    ["[\n", items, "\n", outer_pad, "]"]
  end

  defp pretty(%Mut.JSON.OrderedObject{entries: []}, _depth), do: "{}"

  defp pretty(%Mut.JSON.OrderedObject{entries: entries}, depth) do
    pretty_object(entries, depth)
  end

  defp pretty(%_{} = struct, depth) do
    # Other structs with @derive JSON.Encoder: round-trip through JSON to
    # respect the derive (only/except), then walk the resulting plain map.
    struct
    |> JSON.encode!()
    |> JSON.decode!()
    |> pretty(depth)
  end

  defp pretty(map, depth) when is_map(map) do
    if map_size(map) == 0 do
      "{}"
    else
      pretty_object(Enum.sort_by(Map.to_list(map), fn {k, _} -> to_string(k) end), depth)
    end
  end

  defp pretty_object(entries, depth) do
    inner_pad = String.duplicate(@indent, depth + 1)
    outer_pad = String.duplicate(@indent, depth)

    pairs =
      entries
      |> Enum.map(fn {key, value} ->
        [inner_pad, JSON.encode!(to_string(key)), ": ", pretty(value, depth + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", pairs, "\n", outer_pad, "}"]
  end
end
