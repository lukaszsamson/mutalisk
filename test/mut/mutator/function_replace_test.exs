defmodule Mut.Mutator.FunctionReplaceTest do
  use ExUnit.Case, async: true

  @moduledoc "M76 FunctionReplace: closed-allowlist function swaps."

  import Mut.MutatorTestSupport

  alias Mut.Mutator.FunctionReplace

  defp remote(mod, fun, args),
    do: {{:., [], [{:__aliases__, [], [mod]}, fun]}, [line: 1, column: 1], args}

  defp bare(fun, args), do: {fun, [line: 1, column: 1], args}

  defp ctx(mod, fun, arity),
    do: context_for(fun, oracle_site: site(fun, resolved_module: mod, resolved_arity: arity))

  defp cand(fun, arity),
    do: %{candidate(fun, arity) | node: remote(:Enum, fun, List.duplicate(0, arity))}

  describe "metadata" do
    test "name/targets" do
      assert FunctionReplace.name() == "FunctionReplace"
      assert FunctionReplace.targets() == [:dispatch]
    end
  end

  describe "compatible?" do
    test "matches allowlisted module/name/arity" do
      assert FunctionReplace.compatible?(
               cand(:min, 1),
               site(:min, resolved_module: Enum, resolved_arity: 1)
             )

      assert FunctionReplace.compatible?(
               cand(:filter, 2),
               site(:filter, resolved_module: Enum, resolved_arity: 2)
             )
    end

    test "rejects functions outside the allowlist or wrong module/arity" do
      # Enum.map is not paired.
      refute FunctionReplace.compatible?(
               cand(:map, 2),
               site(:map, resolved_module: Enum, resolved_arity: 2)
             )

      # min/1 resolved to a different module (a shadowing local / other module).
      refute FunctionReplace.compatible?(
               cand(:min, 1),
               site(:min, resolved_module: MyMod, resolved_arity: 1)
             )

      # arity not in the table (Enum.filter/3 doesn't exist in the allowlist).
      refute FunctionReplace.compatible?(
               cand(:filter, 3),
               site(:filter, resolved_module: Enum, resolved_arity: 3)
             )
    end
  end

  describe "mutate" do
    test "swaps Enum.min/1 -> Enum.max (remote form)" do
      node = remote(:Enum, :min, [[3, 1, 2]])
      [m] = FunctionReplace.mutate(node, ctx(Enum, :min, 1))
      assert {{:., _, [{:__aliases__, _, [:Enum]}, :max]}, _, [[3, 1, 2]]} = m.mutated_ast
      assert m.metadata.replacement == :max
      refute FunctionReplace.equivalent?(m)
    end

    test "swaps imported filter/2 -> reject (bare form)" do
      node = bare(:filter, [[1, 2], fn x -> x > 1 end])
      [m] = FunctionReplace.mutate(node, ctx(Enum, :filter, 2))
      assert {:reject, _, [_, _]} = m.mutated_ast
    end

    test "String.starts_with?/2 -> ends_with?" do
      node = remote(:String, :starts_with?, ["abc", "a"])
      [m] = FunctionReplace.mutate(node, ctx(String, :starts_with?, 2))
      assert {{:., _, [{:__aliases__, _, [:String]}, :ends_with?]}, _, _} = m.mutated_ast
    end

    test "no mutation for non-allowlisted call" do
      node = remote(:Enum, :map, [[1], fn x -> x end])
      assert FunctionReplace.mutate(node, ctx(Enum, :map, 2)) == []
    end

    test "not applicable in non-body (guard) context" do
      node = remote(:Enum, :min, [[1, 2]])

      refute FunctionReplace.applicable?(
               node,
               context_for(:min,
                 env_context: :guard,
                 oracle_site: site(:min, resolved_module: Enum, resolved_arity: 1)
               )
             )
    end
  end
end
