defmodule Mut.Mutator.GuardComparisonBoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutator.GuardComparisonBoundary

  import Mut.MutatorTestSupport

  test "filters shape and fallback guard context" do
    assert GuardComparisonBoundary.applicable?(ast_node(:<), fallback_guard_context())
    refute GuardComparisonBoundary.applicable?(ast_node(:==), fallback_guard_context())
    refute GuardComparisonBoundary.applicable?({:<, [], [1]}, fallback_guard_context())
    refute GuardComparisonBoundary.applicable?(ast_node(:<), context(engine: :fallback))
    refute GuardComparisonBoundary.applicable?(ast_node(:<), context(env_context: :guard))

    assert GuardComparisonBoundary.mutate(ast_node(:<), context(engine: :fallback)) == []
  end

  test "emits boundary replacement table" do
    assert replacements(:<) == [:<=]
    assert replacements(:<=) == [:<]
    assert replacements(:>) == [:>=]
    assert replacements(:>=) == [:>]
  end

  test "marks every boundary mutation guard-safe and non-equivalent" do
    mutations = GuardComparisonBoundary.mutate(ast_node(:<), fallback_guard_context())

    assert Enum.all?(mutations, & &1.guard_safe?)
    assert Enum.all?(mutations, &(GuardComparisonBoundary.equivalent?(&1) == false))
  end

  test "checks oracle compatibility" do
    assert GuardComparisonBoundary.compatible?(candidate(:>), site(:>, resolved_module: Kernel))
    assert GuardComparisonBoundary.compatible?(candidate(:>), site(:>, resolved_module: :erlang))
    refute GuardComparisonBoundary.compatible?(candidate(:>), site(:>, resolved_module: Path))
    refute GuardComparisonBoundary.compatible?(candidate(:>), site(:join, resolved_module: Path))
    refute GuardComparisonBoundary.compatible?(candidate(:>), site(:>, resolved_arity: 1))
  end

  defp replacements(op) do
    op
    |> ast_node()
    |> GuardComparisonBoundary.mutate(fallback_guard_context())
    |> Enum.map(& &1.metadata.replacement)
  end

  defp fallback_guard_context, do: context(engine: :fallback, env_context: :guard)
end
