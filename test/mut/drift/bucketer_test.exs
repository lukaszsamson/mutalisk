defmodule Mut.Drift.BucketerTest do
  use ExUnit.Case, async: true

  alias Mut.Drift.Bucketer
  alias Mut.Drift.Bucketer.Result

  defp report(file, mutants) do
    %{"files" => %{file => %{"language" => "elixir", "mutants" => mutants}}}
  end

  defp mutant(id, status, opts \\ []) do
    base = %{"id" => id, "status" => status}

    case Keyword.get(opts, :reason) do
      nil -> base
      reason -> Map.put(base, "statusReason", reason)
    end
  end

  describe "agreement" do
    test "byte-identical reports produce zero drift" do
      mix = report("lib/foo.ex", [mutant("a", "Killed"), mutant("b", "Survived")])
      pers = report("lib/foo.ex", [mutant("a", "Killed"), mutant("b", "Survived")])

      result = Bucketer.analyze(mix, pers, "foo")

      assert Result.drift_total(result) == 0
      assert length(result.agree_killed) == 1
      assert length(result.agree_survived) == 1
    end

    test "matched non-Killed/Survived statuses are agree_other, not drift" do
      mix = report("lib/foo.ex", [mutant("a", "CompileError")])
      pers = report("lib/foo.ex", [mutant("a", "CompileError")])

      result = Bucketer.analyze(mix, pers, "foo")

      assert Result.drift_total(result) == 0
      assert Map.get(result.agree_other, "CompileError") == 1
    end
  end

  describe "drift directions" do
    test "tracks mix_killed_persistent_survived" do
      mix = report("lib/foo.ex", [mutant("a", "Killed")])
      pers = report("lib/foo.ex", [mutant("a", "Survived")])
      result = Bucketer.analyze(mix, pers, "foo")
      assert Result.drift_total(result) == 1
      assert [%{mix_status: "Killed", persistent_status: "Survived"}] = result.drift
    end

    test "tracks mix_survived_persistent_killed" do
      mix = report("lib/foo.ex", [mutant("a", "Survived")])
      pers = report("lib/foo.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "foo")
      assert [%{mix_status: "Survived", persistent_status: "Killed"}] = result.drift
    end
  end

  describe "heuristic buckets" do
    test "timeout_flap fires on either side" do
      mix = report("lib/foo.ex", [mutant("a", "Timeout")])
      pers = report("lib/foo.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "foo")
      assert Map.get(result.buckets, :timeout_flap) == 1
    end

    test "mox_class fires on target name match" do
      mix = report("lib/mox.ex", [mutant("a", "Killed")])
      pers = report("lib/mox.ex", [mutant("a", "Survived")])
      result = Bucketer.analyze(mix, pers, "mox")
      assert Map.get(result.buckets, :mox_class) == 1
    end

    test "mox_class fires on file path even when target name unknown" do
      mix = report("lib/some_mox_helper.ex", [mutant("a", "Survived")])
      pers = report("lib/some_mox_helper.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, nil)
      assert Map.get(result.buckets, :mox_class) == 1
    end

    test "ecto_warm_state catches mix=Killed → persistent=Survived" do
      mix = report("lib/ecto/changeset.ex", [mutant("a", "Killed")])
      pers = report("lib/ecto/changeset.ex", [mutant("a", "Survived")])
      result = Bucketer.analyze(mix, pers, "ecto")
      assert Map.get(result.buckets, :ecto_warm_state) == 1
    end

    test "ecto_warm_state catches mix=RuntimeError → persistent=Killed (warm BEAM masks errors)" do
      mix = report("lib/ecto/query.ex", [mutant("a", "RuntimeError")])
      pers = report("lib/ecto/query.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "ecto")
      assert Map.get(result.buckets, :ecto_warm_state) == 1
    end

    test "ecto_false_kill catches mix=Survived → persistent=Killed" do
      mix = report("lib/ecto/schema.ex", [mutant("a", "Survived")])
      pers = report("lib/ecto/schema.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "ecto")
      assert Map.get(result.buckets, :ecto_false_kill) == 1
    end

    test "gettext_class fires on persistent CompileError for gettext target" do
      mix = report("lib/gettext.ex", [mutant("a", "Killed")])
      pers = report("lib/gettext.ex", [mutant("a", "CompileError")])
      result = Bucketer.analyze(mix, pers, "gettext")
      assert Map.get(result.buckets, :gettext_class) == 1
    end

    test "parse_class fires on SyntaxError statusReason" do
      mix = report("lib/foo.ex", [mutant("a", "Killed")])

      pers =
        report("lib/foo.ex", [
          mutant("a", "CompileError",
            reason: "** (SyntaxError) invalid syntax found on lib/foo.ex:10:5"
          )
        ])

      result = Bucketer.analyze(mix, pers, "foo")
      # parse_class wins over the generic CompileError-only branch
      assert Map.get(result.buckets, :parse_class) == 1
    end

    test "parse_class fires on MismatchedDelimiter" do
      pers =
        report("lib/foo.ex", [
          mutant("a", "Killed",
            reason: "** (MismatchedDelimiterError) mismatched delimiter found"
          )
        ])

      mix = report("lib/foo.ex", [mutant("a", "Survived")])
      result = Bucketer.analyze(mix, pers, "foo")
      assert Map.get(result.buckets, :parse_class) == 1
    end

    test "unclassified for non-matching target with vanilla flip" do
      mix = report("lib/foo.ex", [mutant("a", "Survived")])
      pers = report("lib/foo.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "foo")
      assert Map.get(result.buckets, :unclassified) == 1
    end

    test "timeout_flap takes priority over ecto" do
      mix = report("lib/ecto/x.ex", [mutant("a", "Timeout")])
      pers = report("lib/ecto/x.ex", [mutant("a", "Killed")])
      result = Bucketer.analyze(mix, pers, "ecto")
      assert Map.get(result.buckets, :timeout_flap) == 1
      assert Map.get(result.buckets, :ecto_warm_state) == 0
    end
  end

  describe "presence" do
    test "tracks mix_only and persistent_only ids" do
      mix = report("lib/a.ex", [mutant("a", "Killed")])
      pers = report("lib/a.ex", [mutant("b", "Killed")])
      result = Bucketer.analyze(mix, pers, "a")
      assert "a" in result.mix_only
      assert "b" in result.persistent_only
    end
  end

  describe "Result helpers" do
    test "drift_rate is 0 for empty report" do
      result = Result.new("none")
      assert Result.drift_rate(result) == 0.0
    end

    test "unclassified_rate is 0 when no drift" do
      result = Result.new("none")
      assert Result.unclassified_rate(result) == 0.0
    end
  end
end
