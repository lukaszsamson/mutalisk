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

    test "M78: skips ++ inside codegen function bodies (in_codegen?)" do
      codegen_cand = %{candidate(:++) | in_codegen?: true}
      refute ConcatOperator.compatible?(codegen_cand, site(:++, resolved_module: Kernel))
      # nil / false (normal candidates) are not blocked.
      assert ConcatOperator.compatible?(
               %{candidate(:++) | in_codegen?: false},
               site(:++, resolved_module: Kernel)
             )
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

    # B20: `x not in y` parses as `not(x in y)`. Negating the inner `in` would
    # render `not(not(x in y))` (schema) / splice `x not not(x in y)`
    # (fallback); the enclosing `not` carries the mutation instead.
    test "unwraps not in -> in and suppresses the inner in candidate" do
      [m] = Membership.mutate(not_in_node(), not_context())
      assert {:in, _, [{:x, _, _}, {:y, _, _}]} = m.mutated_ast
      assert m.mutation_kind == :membership_op
      assert m.metadata == %{operator: :not_in, replacement: :in}

      inner_ctx = context_for(:in, ast_path: [{:elem, :=, 1}, {:elem, :not, 0}])
      assert Membership.mutate(in_node(), inner_ctx) == []
    end

    test "not dispatch accepted only for a not-wrapped in node" do
      assert Membership.compatible?(not_in_candidate(), site(:not, resolved_arity: 1))

      assert Membership.compatible?(
               not_in_candidate(),
               site(:not, resolved_arity: 1, resolved_module: :erlang)
             )

      refute Membership.compatible?(
               %{not_in_candidate() | node: unary_node(:not)},
               site(:not, resolved_arity: 1)
             )

      refute Membership.compatible?(
               not_in_candidate(),
               site(:not, resolved_arity: 1, resolved_module: Enum)
             )
    end

    test "both directions render to valid, different source" do
      [wrapped] = Membership.mutate(in_node(), context_for(:in))
      [unwrapped] = Membership.mutate(not_in_node(), not_context())

      assert Macro.to_string(wrapped.mutated_ast) == "x not in y"
      assert Macro.to_string(unwrapped.mutated_ast) == "x in y"
      assert {:ok, _} = Code.string_to_quoted(Macro.to_string(wrapped.mutated_ast))
      assert {:ok, _} = Code.string_to_quoted(Macro.to_string(unwrapped.mutated_ast))

      assert Macro.to_string(wrapped.mutated_ast) != Macro.to_string(wrapped.original_ast)
      assert Macro.to_string(unwrapped.mutated_ast) != Macro.to_string(unwrapped.original_ast)
    end
  end

  defp in_node, do: Code.string_to_quoted!("x in y")

  defp not_in_node, do: Code.string_to_quoted!("x not in y")

  defp not_context do
    context(
      oracle_site: site(:not, resolved_arity: 1),
      ast_path: [{:elem, :=, 1}]
    )
  end

  defp not_in_candidate do
    %{candidate(:not, 1) | node: not_in_node()}
  end
end
