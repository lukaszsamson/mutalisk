defmodule Mut.Mutator.GuardBooleanTest do
  use ExUnit.Case, async: true

  @moduledoc "M90 GuardBoolean — and<->or; not-drop in guards."

  alias Mut.Context
  alias Mut.Mutator.GuardBoolean
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  defp guard_ctx do
    %Context{
      engine: :fallback,
      env_context: :guard,
      file: "m.ex",
      ast_path: [],
      ast_path_hash: "h"
    }
  end

  describe "metadata" do
    test "name/targets" do
      assert GuardBoolean.name() == "GuardBoolean"
      assert GuardBoolean.targets() == [:guard_boolean]
    end
  end

  describe "applicability" do
    test "only in fallback engine and guard env_context" do
      assert GuardBoolean.applicable?({:and, [], [true, true]}, guard_ctx())
      refute GuardBoolean.applicable?({:and, [], [true, true]}, %{guard_ctx() | engine: :schema})
      refute GuardBoolean.applicable?({:and, [], [true, true]}, %{guard_ctx() | env_context: nil})
    end

    test "only on shape-matching nodes" do
      refute GuardBoolean.applicable?({:+, [], [1, 2]}, guard_ctx())
      refute GuardBoolean.applicable?({:and, [], [true]}, guard_ctx())
    end
  end

  describe "mutate/2" do
    test "and <-> or swap" do
      [m] = GuardBoolean.mutate({:and, [line: 1], [true, false]}, guard_ctx())
      assert {:or, _, [true, false]} = m.mutated_ast
      assert m.metadata == %{operator: :and, replacement: :or}
      assert m.guard_safe?

      [m2] = GuardBoolean.mutate({:or, [line: 1], [true, false]}, guard_ctx())
      assert {:and, _, [true, false]} = m2.mutated_ast
    end

    test "not(x) -> x" do
      [m] = GuardBoolean.mutate({:not, [line: 1], [{:is_atom, [], [{:x, [], nil}]}]}, guard_ctx())
      assert {:is_atom, _, [{:x, [], nil}]} = m.mutated_ast
      assert m.metadata == %{operator: :not, replacement: :drop}
      assert m.guard_safe?
    end

    test "non-applicable returns []" do
      assert GuardBoolean.mutate({:+, [], [1, 2]}, guard_ctx()) == []
    end
  end

  describe "compatible?/2" do
    test "matches Kernel/erlang and/or/not by name and arity" do
      cand = fn name, arity ->
        %AstCandidate{
          file: "m.ex",
          line: 1,
          column: 1,
          syntactic_name: name,
          syntactic_arity: arity,
          source_span: nil,
          env_context: :guard,
          enclosing_module: nil,
          ast_path: [],
          ast_path_hash: "h",
          node: {name, [], List.duplicate(true, arity)}
        }
      end

      site = fn name, arity ->
        %DispatchSite{
          file: "m.ex",
          line: 1,
          dispatch_kind: :imported_function,
          resolved_module: Kernel,
          resolved_name: name,
          resolved_arity: arity,
          event_file: "m.ex",
          env_context: :guard
        }
      end

      assert GuardBoolean.compatible?(cand.(:and, 2), site.(:and, 2))
      assert GuardBoolean.compatible?(cand.(:or, 2), site.(:or, 2))
      assert GuardBoolean.compatible?(cand.(:not, 1), site.(:not, 1))
      # Mismatched names / arities / modules → false.
      refute GuardBoolean.compatible?(cand.(:and, 2), site.(:or, 2))
    end
  end
end
