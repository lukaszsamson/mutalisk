defmodule Mut.Mutator.ComparisonNegationTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.ComparisonNegation

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert ComparisonNegation.applicable?(ast_node(:==), context())
    refute ComparisonNegation.applicable?(ast_node(:and), context())
    refute ComparisonNegation.applicable?({:==, [], [1]}, context())
    refute ComparisonNegation.applicable?(ast_node(:==), context(env_context: :guard))
    assert ComparisonNegation.mutate(ast_node(:==), context(env_context: :guard)) == []
  end

  test "emits negation replacement table" do
    assert replacements(ComparisonNegation, :<) == [:>=]
    assert replacements(ComparisonNegation, :<=) == [:>]
    assert replacements(ComparisonNegation, :>) == [:<=]
    assert replacements(ComparisonNegation, :>=) == [:<]
    assert replacements(ComparisonNegation, :==) == [:!=]
    assert replacements(ComparisonNegation, :!=) == [:==]
    assert replacements(ComparisonNegation, :===) == [:!==]
    assert replacements(ComparisonNegation, :!==) == [:===]
  end

  test "marks every negation mutation guard-safe and non-equivalent" do
    mutations = ComparisonNegation.mutate(ast_node(:==), context())

    assert Enum.all?(mutations, & &1.guard_safe?)
    assert Enum.all?(mutations, &(ComparisonNegation.equivalent?(&1) == false))
  end

  test "checks oracle compatibility" do
    assert ComparisonNegation.compatible?(candidate(:==), site(:==, resolved_module: Kernel))
    assert ComparisonNegation.compatible?(candidate(:<), site(:<, resolved_module: :erlang))
    refute ComparisonNegation.compatible?(candidate(:and), site(:and, resolved_module: Kernel))
    refute ComparisonNegation.compatible?(candidate(:==), site(:==, resolved_module: Path))
    refute ComparisonNegation.compatible?(candidate(:==), site(:==, resolved_arity: 1))
  end
end
