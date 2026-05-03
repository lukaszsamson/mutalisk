defmodule Mut.Mutator.ComparisonNegationTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.ComparisonNegation

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert ComparisonNegation.applicable?(ast_node(:==), context_for(:==))
    refute ComparisonNegation.applicable?(ast_node(:and), context_for(:and))
    refute ComparisonNegation.applicable?({:==, [], [1]}, context_for(:==))
    refute ComparisonNegation.applicable?(ast_node(:==), context_for(:==, env_context: :guard))

    refute ComparisonNegation.applicable?(
             ast_node(:==),
             context_for(:==, oracle_site: site(:==, resolved_module: Path))
           )

    assert ComparisonNegation.mutate(ast_node(:==), context_for(:==, env_context: :guard)) == []
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
    mutations = ComparisonNegation.mutate(ast_node(:==), context_for(:==))

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
