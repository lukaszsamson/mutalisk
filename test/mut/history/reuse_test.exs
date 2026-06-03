defmodule Mut.History.ReuseTest do
  use ExUnit.Case, async: true

  alias Mut.History.Reuse
  alias Mut.Mutant

  defp mutant(stable_id, file \\ "lib/m.ex") do
    %Mutant{
      id: 0,
      stable_id: stable_id,
      engine: :schema,
      mutator: M,
      mutator_name: "M",
      original_ast: nil,
      mutated_ast: nil,
      description: "d",
      file: file,
      line: 1
    }
  end

  defp stored(status, opts \\ []) do
    %{
      "status" => status,
      "source_digest" => Keyword.get(opts, :source_digest, "S"),
      "selected_tests_digest" => Keyword.get(opts, :selected_tests_digest, "T"),
      "project_digest" => Keyword.get(opts, :project_digest, "P"),
      "test_timeout_ms" => Keyword.get(opts, :test_timeout_ms, 10_000)
    }
  end

  defp current(opts \\ []) do
    %{
      source_digest: Keyword.get(opts, :source_digest, "S"),
      selected_tests_digest: Keyword.get(opts, :selected_tests_digest, "T"),
      project_digest: Keyword.get(opts, :project_digest, "P"),
      test_timeout_ms: Keyword.get(opts, :test_timeout_ms, 10_000)
    }
  end

  describe "decide" do
    test "no stored entry -> execute" do
      assert Reuse.decide(mutant("a"), %{}, current()) == :execute
    end

    test "matching source + selected tests -> reuse (killed)" do
      verdicts = %{"a" => stored("killed")}
      assert {:reuse, %{"status" => "killed"}} = Reuse.decide(mutant("a"), verdicts, current())
    end

    test "matching -> reuse (survived)" do
      verdicts = %{"a" => stored("survived")}
      assert {:reuse, _} = Reuse.decide(mutant("a"), verdicts, current())
    end

    test "source digest changed -> execute" do
      verdicts = %{"a" => stored("killed", source_digest: "OLD")}
      assert Reuse.decide(mutant("a"), verdicts, current(source_digest: "NEW")) == :execute
    end

    test "selected tests changed -> execute (survivor could now be killed)" do
      verdicts = %{"a" => stored("survived", selected_tests_digest: "OLD")}

      assert Reuse.decide(mutant("a"), verdicts, current(selected_tests_digest: "NEW")) ==
               :execute
    end

    # P1a: a change to any project source/test-support/config/dep changes the
    # project fingerprint and invalidates reuse, even when the per-mutant
    # function + selected-test digests still match.
    test "project fingerprint changed -> execute" do
      verdicts = %{"a" => stored("survived", project_digest: "OLD")}
      assert Reuse.decide(mutant("a"), verdicts, current(project_digest: "NEW")) == :execute
    end

    # P1b: the timeout budget gates ALL statuses, not just stored "timeout" —
    # lowering it can turn a survived mutant into a timeout detection.
    test "timeout budget change -> execute for every status" do
      for status <- ["killed", "survived", "timeout"] do
        verdicts = %{"a" => stored(status, test_timeout_ms: 10_000)}
        assert {:reuse, _} = Reuse.decide(mutant("a"), verdicts, current(test_timeout_ms: 10_000))
        assert Reuse.decide(mutant("a"), verdicts, current(test_timeout_ms: 20_000)) == :execute
      end
    end

    test "--since changed file -> execute even on a digest match" do
      verdicts = %{"a" => stored("killed")}
      assert Reuse.decide(mutant("a"), verdicts, current(), true) == :execute
    end
  end
end
