defmodule Mut.Mutator.OperatorExpansionTest do
  use ExUnit.Case, async: true

  @moduledoc "M69 operator-expansion mutators: ConcatOperator, BitwiseOperator, Membership."

  import Mut.MutatorTestSupport

  alias Mut.Mutator.BitwiseOperator
  alias Mut.Mutator.ConcatOperator
  alias Mut.Mutator.Membership

  describe "ConcatOperator" do
    test "metadata + replacement table" do
      assert ConcatOperator.name() == "ConcatOperator"
      assert ConcatOperator.targets() == [:dispatch]
      assert replacements(ConcatOperator, :++) == [:--]
      # M72 hazard rule: the crash-prone `--` -> `++` direction is dropped.
      assert replacements(ConcatOperator, :--) == []
    end

    test "applicable only for ++ body dispatch with matching oracle (M72: not --)" do
      assert ConcatOperator.applicable?(ast_node(:++), context_for(:++))
      refute ConcatOperator.applicable?(ast_node(:--), context_for(:--))
      refute ConcatOperator.applicable?(ast_node(:+), context_for(:+))
      refute ConcatOperator.applicable?(ast_node(:++), context_for(:++, env_context: :guard))

      refute ConcatOperator.applicable?(
               ast_node(:++),
               context_for(:++, oracle_site: site(:++, resolved_module: List))
             )
    end

    test "oracle compatibility + guard-safe non-equivalent" do
      assert ConcatOperator.compatible?(candidate(:++), site(:++, resolved_module: Kernel))
      refute ConcatOperator.compatible?(candidate(:++), site(:++, resolved_arity: 1))
      refute ConcatOperator.compatible?(candidate(:--), site(:--, resolved_module: Kernel))
      ms = ConcatOperator.mutate(ast_node(:++), context_for(:++))
      assert Enum.all?(ms, &(&1.guard_safe? and ConcatOperator.equivalent?(&1) == false))
    end
  end

  describe "BitwiseOperator" do
    test "replacement table" do
      # context_for/1 defaults the oracle module to Kernel; bitwise needs Bitwise.
      bw = fn op ->
        ast_node(op)
        |> BitwiseOperator.mutate(
          context_for(op, oracle_site: site(op, resolved_module: Bitwise))
        )
        |> Enum.map(& &1.metadata.replacement)
      end

      assert bw.(:band) == [:bor, :bxor]
      # M72: bor <-> bxor dropped (input-dependent pseudo-equivalents).
      assert bw.(:bor) == [:band]
      assert bw.(:bxor) == [:band]
      assert bw.(:bsl) == [:bsr]
      assert bw.(:bsr) == [:bsl]
    end

    test "compatible with Bitwise / :erlang, not other modules" do
      assert BitwiseOperator.compatible?(candidate(:band), site(:band, resolved_module: Bitwise))
      assert BitwiseOperator.compatible?(candidate(:bsl), site(:bsl, resolved_module: :erlang))
      refute BitwiseOperator.compatible?(candidate(:band), site(:band, resolved_module: Kernel))
      refute BitwiseOperator.applicable?(ast_node(:+), context_for(:+))
    end
  end

  describe "Membership" do
    test "negates in -> not (x in y)" do
      assert Membership.targets() == [:dispatch]
      [m] = Membership.mutate(ast_node(:in), context_for(:in))
      assert {:not, _, [{:in, _, [1, 2]}]} = m.mutated_ast
      assert m.mutation_kind == :membership_op
      refute Membership.equivalent?(m)
    end

    test "applicable only for in/2 dispatch; compatibility" do
      assert Membership.applicable?(ast_node(:in), context_for(:in))
      refute Membership.applicable?(ast_node(:++), context_for(:++))
      assert Membership.compatible?(candidate(:in), site(:in, resolved_module: Kernel))
      refute Membership.compatible?(candidate(:in), site(:in, resolved_module: Enum))
    end
  end
end
