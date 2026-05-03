defmodule Mut.Mutator.GuardComparisonNegationTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.GuardComparisonNegation

  import Mut.MutatorTestSupport

  test "filters shape and fallback guard context" do
    assert GuardComparisonNegation.applicable?(ast_node(:==), fallback_guard_context())
    refute GuardComparisonNegation.applicable?(ast_node(:+), fallback_guard_context())
    refute GuardComparisonNegation.applicable?(ast_node(:==), context(engine: :fallback))
    refute GuardComparisonNegation.applicable?(ast_node(:==), context(env_context: :guard))
  end

  test "emits negation replacement table" do
    assert replacements(:<) == [:>=]
    assert replacements(:<=) == [:>]
    assert replacements(:>) == [:<=]
    assert replacements(:>=) == [:<]
    assert replacements(:==) == [:!=]
    assert replacements(:!=) == [:==]
    assert replacements(:===) == [:!==]
    assert replacements(:!==) == [:===]
  end

  test "marks every negation mutation guard-safe" do
    mutations = GuardComparisonNegation.mutate(ast_node(:==), fallback_guard_context())

    assert Enum.all?(mutations, & &1.guard_safe?)
  end

  test "checks oracle compatibility" do
    assert GuardComparisonNegation.compatible?(candidate(:==), site(:==, resolved_module: Kernel))

    assert GuardComparisonNegation.compatible?(
             candidate(:==),
             site(:==, resolved_module: :erlang)
           )

    refute GuardComparisonNegation.compatible?(candidate(:==), site(:==, resolved_module: Path))
    refute GuardComparisonNegation.compatible?(candidate(:==), site(:join, resolved_module: Path))
    refute GuardComparisonNegation.compatible?(candidate(:==), site(:==, resolved_arity: 1))
  end

  defp replacements(op) do
    op
    |> ast_node()
    |> GuardComparisonNegation.mutate(fallback_guard_context())
    |> Enum.map(& &1.metadata.replacement)
  end

  defp fallback_guard_context, do: context(engine: :fallback, env_context: :guard)
end
