defmodule Mut.Mutator.ComparisonBoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.ComparisonBoundary

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert ComparisonBoundary.applicable?(ast_node(:<), context_for(:<))
    refute ComparisonBoundary.applicable?(ast_node(:==), context_for(:==))
    refute ComparisonBoundary.applicable?({:<, [], [1]}, context_for(:<))
    refute ComparisonBoundary.applicable?(ast_node(:<), context_for(:<, env_context: :guard))

    refute ComparisonBoundary.applicable?(
             ast_node(:<),
             context_for(:<, oracle_site: site(:<, resolved_module: Path))
           )

    assert ComparisonBoundary.mutate(ast_node(:<), context_for(:<, env_context: :guard)) == []
  end

  test "emits boundary replacement table" do
    assert replacements(ComparisonBoundary, :<) == [:<=]
    assert replacements(ComparisonBoundary, :<=) == [:<]
    assert replacements(ComparisonBoundary, :>) == [:>=]
    assert replacements(ComparisonBoundary, :>=) == [:>]
  end

  test "marks every boundary mutation guard-safe and non-equivalent" do
    mutations = ComparisonBoundary.mutate(ast_node(:<), context_for(:<))

    assert Enum.all?(mutations, & &1.guard_safe?)
    assert Enum.all?(mutations, &(ComparisonBoundary.equivalent?(&1) == false))
  end

  test "checks oracle compatibility" do
    assert ComparisonBoundary.compatible?(candidate(:<), site(:<, resolved_module: Kernel))
    assert ComparisonBoundary.compatible?(candidate(:<), site(:<, resolved_module: :erlang))
    refute ComparisonBoundary.compatible?(candidate(:==), site(:==, resolved_module: Kernel))
    refute ComparisonBoundary.compatible?(candidate(:<), site(:<, resolved_module: Path))
    refute ComparisonBoundary.compatible?(candidate(:<), site(:<, resolved_arity: 1))
  end
end
