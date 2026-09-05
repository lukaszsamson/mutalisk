defmodule Mut.Mutator.AttributeLiteral do
  @moduledoc "Mutates module attribute literal values."
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "AttributeLiteral"

  @impl true
  def description, do: "Replace module attribute literal values."

  @impl true
  def targets, do: [:module_attribute]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and replacements(node) != []
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t()) :: false
  def compatible?(%AstCandidate{}, %DispatchSite{}), do: false

  defp build_mutations(node) do
    node
    |> replacements()
    |> Enum.map(fn {replacement, kind} -> mutation(node, replacement, kind) end)
  end

  # Drop replacements equal to the source value (they would render
  # byte-identical to the original and always survive) and collapse
  # duplicates (e.g. `-1` maps to both `0` and `-1 + 1`).
  defp replacements(value) do
    value
    |> raw_replacements()
    |> Enum.reject(fn {replacement, _kind} -> replacement === value end)
    |> Enum.uniq_by(fn {replacement, _kind} -> replacement end)
  end

  defp raw_replacements(value) when is_boolean(value), do: [{not value, :attribute_bool_flip}]

  defp raw_replacements(value) when is_integer(value),
    do: [{0, :attribute_int_replace}, {value + 1, :attribute_int_replace}]

  defp raw_replacements(value) when is_float(value),
    do: [{0.0, :attribute_float_replace}, {value + 1.0, :attribute_float_replace}]

  defp raw_replacements(""), do: []
  defp raw_replacements(value) when is_binary(value), do: [{"", :attribute_string_replace}]

  defp raw_replacements(value) when is_list(value),
    do: if(charlist?(value), do: [{[], :attribute_charlist_replace}], else: [])

  defp raw_replacements(value) when is_atom(value), do: []
  defp raw_replacements(_value), do: []

  defp charlist?(list), do: list != [] and Enum.all?(list, &is_integer/1)

  defp mutation(original, replacement, kind) do
    %Mutation{
      original_ast: original,
      mutated_ast: replacement,
      description: "replace attribute literal #{inspect(original)} with #{inspect(replacement)}",
      mutation_kind: kind,
      guard_safe?: false,
      metadata: %{original_value: original, replacement_value: replacement}
    }
  end
end
