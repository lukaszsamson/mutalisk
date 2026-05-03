defmodule Mut.Mutator.UnaryNotTest do
  use ExUnit.Case, async: true

  @moduledoc false
  alias Mut.Mutator.UnaryNot

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert UnaryNot.applicable?(unary_node(:not), context_for(:not))
    refute UnaryNot.applicable?(ast_node(:not), context_for(:not))
    refute UnaryNot.applicable?(ast_node(:+), context_for(:+))
    refute UnaryNot.applicable?(unary_node(:not), context_for(:not, env_context: :guard))

    refute UnaryNot.applicable?(
             unary_node(:not),
             context_for(:not, oracle_site: site(:not, resolved_module: Path, resolved_arity: 1))
           )

    assert UnaryNot.mutate(unary_node(:not), context_for(:not, env_context: :guard)) == []
  end

  test "removes unary not operators" do
    assert [not_mutation] = UnaryNot.mutate(unary_node(:not), context_for(:not))
    assert not_mutation.mutated_ast == {:x, [], nil}
    assert not_mutation.description == "remove unary not"
    assert not_mutation.metadata == %{operator: :not, replacement: nil}

    assert [bang_mutation] = UnaryNot.mutate(unary_node(:!), context_for(:!))
    assert bang_mutation.mutated_ast == {:x, [], nil}
    assert bang_mutation.description == "remove unary !"
    assert bang_mutation.metadata == %{operator: :!, replacement: nil}
  end

  test "marks unary removals guard-safe and non-equivalent" do
    mutations = UnaryNot.mutate(unary_node(:!), context_for(:!))

    assert Enum.all?(mutations, & &1.guard_safe?)
    assert Enum.all?(mutations, &(UnaryNot.equivalent?(&1) == false))
  end

  test "checks oracle compatibility" do
    assert UnaryNot.compatible?(candidate(:not, 1), site(:not, resolved_arity: 1))

    assert UnaryNot.compatible?(
             candidate(:!, 1),
             site(:!, resolved_module: :erlang, resolved_arity: 1)
           )

    refute UnaryNot.compatible?(
             candidate(:not, 1),
             site(:not, resolved_module: Path, resolved_arity: 1)
           )

    refute UnaryNot.compatible?(candidate(:not, 1), site(:not, resolved_arity: 2))
  end
end
