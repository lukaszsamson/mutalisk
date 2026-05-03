defmodule Mut.Mutator.BooleanTest do
  use ExUnit.Case, async: true

  @moduledoc false
  alias Mut.Mutator.Boolean

  import Mut.MutatorTestSupport

  test "filters shape and body context" do
    assert Boolean.applicable?(ast_node(:and), context())
    refute Boolean.applicable?(ast_node(:+), context())
    refute Boolean.applicable?({:and, [], [true]}, context())
    refute Boolean.applicable?(ast_node(:and), context(env_context: :guard))
    assert Boolean.mutate(ast_node(:and), context(env_context: :guard)) == []
  end

  test "emits boolean replacement table" do
    assert replacements(Boolean, :and) == [:or]
    assert replacements(Boolean, :or) == [:and]
    assert replacements(Boolean, :&&) == [:||]
    assert replacements(Boolean, :||) == [:&&]
  end

  test "marks strict boolean mutations guard-safe and truthy mutations unsafe" do
    assert [strict] = Boolean.mutate(ast_node(:and), context())
    assert strict.guard_safe?
    assert [truthy] = Boolean.mutate(ast_node(:||), context())
    refute truthy.guard_safe?
    refute Boolean.equivalent?(strict)
  end

  test "checks oracle compatibility" do
    assert Boolean.compatible?(candidate(:&&), site(:&&, resolved_module: Kernel))
    assert Boolean.compatible?(candidate(:and), site(:and, resolved_module: :erlang))
    refute Boolean.compatible?(candidate(:&&), site(:&&, resolved_module: UserOverride))
    refute Boolean.compatible?(candidate(:&&), site(:&&, resolved_module: :erlang))
    refute Boolean.compatible?(candidate(:&&), site(:&&, resolved_arity: 1))
  end
end
