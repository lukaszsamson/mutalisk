defmodule Mut.Mutator.AttributeLiteralTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.AttributeLiteral

  import Mut.MutatorTestSupport

  test "filters fallback engine and literal shape" do
    assert AttributeLiteral.applicable?(42, fallback_context())
    assert AttributeLiteral.applicable?("value", fallback_context())
    refute AttributeLiteral.applicable?(42, context())
    refute AttributeLiteral.applicable?({:compile_env, [], []}, fallback_context())
    refute AttributeLiteral.applicable?([1, :two], fallback_context())
    refute AttributeLiteral.applicable?(:ok, fallback_context())
  end

  test "emits integer replacements" do
    assert entries(42) == [
             {:attribute_int_replace, 0, %{original_value: 42, replacement_value: 0}},
             {:attribute_int_replace, 43, %{original_value: 42, replacement_value: 43}}
           ]
  end

  test "emits float replacements" do
    assert entries(1.5) == [
             {:attribute_float_replace, 0.0, %{original_value: 1.5, replacement_value: 0.0}},
             {:attribute_float_replace, 2.5, %{original_value: 1.5, replacement_value: 2.5}}
           ]
  end

  test "emits boolean flips" do
    assert entries(true) == [
             {:attribute_bool_flip, false, %{original_value: true, replacement_value: false}}
           ]

    assert entries(false) == [
             {:attribute_bool_flip, true, %{original_value: false, replacement_value: true}}
           ]
  end

  test "emits string and charlist replacements" do
    assert entries("abc") == [
             {:attribute_string_replace, "", %{original_value: "abc", replacement_value: ""}}
           ]

    assert entries(early_charlist()) == [
             {:attribute_charlist_replace, [],
              %{original_value: early_charlist(), replacement_value: []}}
           ]

    assert entries("") == []
    assert entries([]) == []
  end

  test "compatible callback is always false" do
    refute AttributeLiteral.compatible?(candidate(:some_const), site(:+))
  end

  defp entries(node) do
    node
    |> AttributeLiteral.mutate(fallback_context())
    |> Enum.map(&{&1.mutation_kind, &1.mutated_ast, &1.metadata})
  end

  defp fallback_context, do: context(engine: :fallback)

  defp early_charlist, do: [97, 98, 99]
end
