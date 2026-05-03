defmodule Mut.StableId do
  @moduledoc "Computes deterministic stable mutant IDs."

  alias Mut.Mutant

  @type input_map :: %{
          required(:relative_file_path) => Path.t(),
          required(:start_byte) => non_neg_integer() | nil,
          required(:end_byte) => non_neg_integer() | nil,
          required(:mutator_name) => String.t(),
          required(:original_dispatch) => String.t(),
          required(:mutation_kind) => atom() | String.t(),
          optional(:ast_path_hash) => String.t() | nil,
          optional(:original_source) => String.t() | nil
        }

  @spec compute(Mutant.t() | input_map) :: String.t()
  def compute(%Mutant{} = mutant) do
    compute(%{
      relative_file_path: mutant.file,
      start_byte: mutant.start_byte,
      end_byte: mutant.end_byte,
      mutator_name: mutant.mutator_name,
      original_dispatch: mutant.original_dispatch || "",
      mutation_kind: mutant.stable_id_kind || mutant.mutation_kind,
      ast_path_hash: mutant.ast_path_hash,
      original_source: mutant.original_source
    })
  end

  def compute(input) when is_map(input) do
    fallback = fallback_offset(input)

    [
      input.relative_file_path,
      offset(input.start_byte, fallback),
      offset(input.end_byte, fallback),
      input.mutator_name,
      input.original_dispatch,
      to_string(input.mutation_kind)
    ]
    |> Enum.join(<<0>>)
    |> sha256_128_hex()
  end

  defp offset(nil, fallback), do: fallback
  defp offset(offset, _fallback), do: Integer.to_string(offset)

  defp fallback_offset(input) do
    [Map.get(input, :ast_path_hash), normalize_source(Map.get(input, :original_source))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp normalize_source(nil), do: nil

  defp normalize_source(source), do: source |> String.trim() |> String.replace(~r/\s+/, " ")

  defp sha256_128_hex(input) do
    :sha256
    |> :crypto.hash(input)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end
end
