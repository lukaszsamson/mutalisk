defmodule Mut.EnvSnapshotTest do
  use ExUnit.Case, async: true

  alias Mut.EnvSnapshot

  defp eligible_snap(overrides \\ []) do
    %EnvSnapshot{
      file: "lib/foo.ex",
      line: 1,
      column: 1,
      source_span: {0, 10},
      scope: :function_body,
      context: nil,
      trust_level: :trusted
    }
    |> struct(overrides)
  end

  describe "body_literal_eligible?/1" do
    test "returns true for trusted function-body normal-context node with source span" do
      assert EnvSnapshot.body_literal_eligible?(eligible_snap())
    end

    test "returns false for match context" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(context: :match))
    end

    test "returns false for guard context" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(context: :guard))
    end

    test "returns false for module-body scope" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(scope: :module_body))
    end

    test "returns false for attr_value scope" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(scope: :attr_value))
    end

    test "returns false for function_head scope" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(scope: :function_head))
    end

    test "returns false for macro_definition scope" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(scope: :macro_definition))
    end

    test "returns false for opaque trust" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(trust_level: :opaque))
    end

    test "returns false for untrusted_descendant trust" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(trust_level: :untrusted_descendant))
    end

    test "returns false for quoted trust" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(trust_level: :quoted))
    end

    test "returns false for generated trust" do
      refute EnvSnapshot.body_literal_eligible?(eligible_snap(trust_level: :generated))
    end
  end

  describe "skip_reason/1" do
    test "returns nil for eligible snapshot" do
      assert EnvSnapshot.skip_reason(eligible_snap()) == nil
    end

    test "trust_level takes priority over context/scope" do
      snap = eligible_snap(trust_level: :opaque, context: :match, scope: :module_body)
      assert EnvSnapshot.skip_reason(snap) == :opaque
    end

    test "quoted reason wins over generated" do
      snap = eligible_snap(trust_level: :quoted)
      assert EnvSnapshot.skip_reason(snap) == :quoted
    end

    test "missing_span fires when source_span is nil and trust is trusted" do
      snap = eligible_snap(source_span: nil)
      assert EnvSnapshot.skip_reason(snap) == :missing_span
    end

    test "match_context fires for trusted match-context body literal" do
      snap = eligible_snap(context: :match)
      assert EnvSnapshot.skip_reason(snap) == :match_context
    end

    test "guard_context fires for trusted guard-context body literal" do
      snap = eligible_snap(context: :guard)
      assert EnvSnapshot.skip_reason(snap) == :guard_context
    end

    test "module_body scope skip reason" do
      snap = eligible_snap(scope: :module_body)
      assert EnvSnapshot.skip_reason(snap) == :module_body
    end

    test "top_level scope skip reason" do
      snap = eligible_snap(scope: :top_level)
      assert EnvSnapshot.skip_reason(snap) == :top_level
    end

    test "macro_definition scope skip reason" do
      snap = eligible_snap(scope: :macro_definition)
      assert EnvSnapshot.skip_reason(snap) == :macro_definition
    end
  end

  describe "defaults" do
    test "new struct defaults to trusted top_level normal-context with empty binding scope" do
      snap = %EnvSnapshot{}
      assert snap.context == nil
      assert snap.scope == :top_level
      assert snap.trust_level == :trusted
      assert match?(%MapSet{}, snap.bound_vars)
      assert MapSet.size(snap.bound_vars) == 0
    end
  end
end
