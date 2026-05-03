defmodule Mut.Mutator.GuardTypeTestTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.GuardTypeTest

  import Mut.MutatorTestSupport

  @expected %{
    is_integer: [:is_float, :is_number],
    is_float: [:is_integer, :is_number],
    is_number: [:is_integer, :is_float],
    is_atom: [:is_nil],
    is_nil: [:is_atom],
    is_list: [:is_tuple],
    is_tuple: [:is_list],
    is_map: [:is_list],
    is_binary: [],
    is_boolean: [],
    is_pid: [],
    is_port: [],
    is_reference: []
  }

  test "filters shape and fallback guard context" do
    assert GuardTypeTest.applicable?(type_node(:is_integer), fallback_guard_context())
    refute GuardTypeTest.applicable?(type_node(:is_function), fallback_guard_context())
    refute GuardTypeTest.applicable?({:is_integer, [], [:x, 1]}, fallback_guard_context())
    refute GuardTypeTest.applicable?(type_node(:is_integer), context(engine: :fallback))
    refute GuardTypeTest.applicable?(type_node(:is_integer), context(env_context: :guard))
  end

  test "emits full v1 replacement table" do
    for {name, expected} <- @expected do
      assert replacements(name) == expected
    end
  end

  test "marks every type-test mutation guard-safe" do
    mutations = GuardTypeTest.mutate(type_node(:is_integer), fallback_guard_context())

    assert Enum.all?(mutations, & &1.guard_safe?)
  end

  test "checks oracle compatibility" do
    assert GuardTypeTest.compatible?(type_candidate(:is_integer), type_site(:is_integer, Kernel))
    assert GuardTypeTest.compatible?(type_candidate(:is_integer), type_site(:is_integer, :erlang))
    refute GuardTypeTest.compatible?(type_candidate(:is_integer), type_site(:is_integer, Path))

    refute GuardTypeTest.compatible?(
             type_candidate(:is_function),
             type_site(:is_function, Kernel)
           )

    refute GuardTypeTest.compatible?(
             type_candidate(:is_integer),
             site(:is_integer, resolved_arity: 2)
           )
  end

  defp replacements(name) do
    name
    |> type_node()
    |> GuardTypeTest.mutate(fallback_guard_context())
    |> Enum.map(& &1.metadata.replacement)
  end

  defp type_node(name), do: {name, [line: 1, column: 1], [{:x, [], nil}]}

  defp type_candidate(name) do
    %{candidate(name, 1) | node: type_node(name)}
  end

  defp type_site(name, module) do
    site(name, resolved_module: module, resolved_arity: 1)
  end

  defp fallback_guard_context, do: context(engine: :fallback, env_context: :guard)
end
