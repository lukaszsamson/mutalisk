defmodule Mut.Mutator.ArithmeticTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.Arithmetic

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert Arithmetic.applicable?(ast_node(:+), context())
    refute Arithmetic.applicable?(ast_node(:==), context())
    refute Arithmetic.applicable?({:+, [], [1]}, context())
    refute Arithmetic.applicable?(ast_node(:+), context(env_context: :guard))
    assert Arithmetic.mutate(ast_node(:+), context(env_context: :guard)) == []
  end

  test "emits arithmetic replacement table" do
    assert replacements(Arithmetic, :+) == [:-, :*]
    assert replacements(Arithmetic, :-) == [:+, :*]
    assert replacements(Arithmetic, :*) == [:+, :-, :/]
    assert replacements(Arithmetic, :/) == [:*]
    assert replacements(Arithmetic, :div) == [:rem]
    assert replacements(Arithmetic, :rem) == [:div]
  end

  test "marks every arithmetic mutation guard-safe and non-equivalent" do
    mutations = Arithmetic.mutate(ast_node(:*), context())

    assert Enum.all?(mutations, & &1.guard_safe?)
    assert Enum.all?(mutations, &(Arithmetic.equivalent?(&1) == false))
  end

  test "checks oracle compatibility" do
    assert Arithmetic.compatible?(candidate(:+), site(:+, resolved_module: Kernel))
    assert Arithmetic.compatible?(candidate(:+), site(:+, resolved_module: :erlang))
    refute Arithmetic.compatible?(candidate(:+), site(:+, resolved_module: Path))
    refute Arithmetic.compatible?(candidate(:+), site(:join, resolved_module: Path))
    refute Arithmetic.compatible?(candidate(:+), site(:+, resolved_arity: 1))
  end
end
