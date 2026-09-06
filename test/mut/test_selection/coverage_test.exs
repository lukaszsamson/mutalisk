defmodule Mut.TestSelection.CoverageTest do
  use ExUnit.Case, async: true

  alias Mut.CoverageOracle
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.TestSelection.Coverage

  test "selects exact line coverage first" do
    plan = plan([mutant("exact", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{{"lib/sample.ex", 10} => MapSet.new([{:file, "test/exact_test.exs"}])},
      by_function: %{{Sample, :run, 1} => MapSet.new([{:file, "test/function_test.exs"}])}
    }

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["exact"] == %{test_files: ["test/exact_test.exs"], match_kind: :exact_line}
  end

  test "M64: a degraded test file's static coverage is unioned into the selection" do
    plan = plan([mutant("deg", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{{"lib/sample.ex", 10} => MapSet.new([{:file, "test/exact_test.exs"}])},
      degraded_test_files: [{"test/static_test.exs", :coverage_test_timeout}]
    }

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    # the degraded file runs alongside the coverage-selected file (no false survivor)
    assert Enum.sort(result["deg"].test_files) == ["test/exact_test.exs", "test/static_test.exs"]
  end

  test "M64: degraded union works across the abs-analysis / rel-degraded namespace split" do
    # The real orchestrator scenario: static analysis + all_test_files are
    # ABSOLUTE (work-copy-rooted), but the oracle records degraded files
    # RELATIVE-to-root. Without `:root` normalization the degraded union
    # silently contributed nothing (the bug). With it, the degraded file that
    # statically covers the mutant is unioned in.
    root = "/work/copy"
    abs_static = "/work/copy/test/static_test.exs"
    abs_exact = "/work/copy/test/exact_test.exs"

    plan = plan([mutant("deg", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{{"lib/sample.ex", 10} => MapSet.new([{:file, "test/exact_test.exs"}])},
      # oracle records degraded files relative-to-root
      degraded_test_files: [{"test/static_test.exs", :coverage_test_timeout}]
    }

    # analysis + all_test_files are absolute (as the orchestrator builds them)
    result =
      Coverage.for_plan(plan, oracle, %{Sample => MapSet.new([abs_static])},
        all_test_files: [abs_static, abs_exact],
        root: root
      )

    # The degraded file is unioned in, and the selection is canonicalized to
    # the oracle's relative-to-root namespace (so ordering/metrics compare
    # like with like; the worker relativizes either form anyway).
    assert "test/static_test.exs" in result["deg"].test_files,
           "degraded file that statically covers the mutant must be unioned despite the namespace split"

    assert Enum.all?(result["deg"].test_files, &(not absolute?(&1))),
           "selection should be normalized to relative-to-root: #{inspect(result["deg"].test_files)}"
  end

  defp absolute?(path), do: String.starts_with?(path, "/")

  test "a degraded file is unioned in even without static evidence for the mutant" do
    # Degraded coverage is UNKNOWN coverage. The static index only names
    # modules referenced directly in test sources, so "no static evidence" is
    # not proof of irrelevance — the degraded test may reach the mutant through
    # a facade. Selecting it is the only sound answer.
    plan = plan([mutant("unrel", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{{"lib/sample.ex", 10} => MapSet.new([{:file, "test/exact_test.exs"}])},
      degraded_test_files: [{"test/other_test.exs", :coverage_test_failed}]
    }

    result = Coverage.for_plan(plan, oracle, %{Other => MapSet.new(["test/other_test.exs"])})

    assert Enum.sort(result["unrel"].test_files) == [
             "test/exact_test.exs",
             "test/other_test.exs"
           ]
  end

  test "falls back to enclosing function coverage" do
    plan = plan([mutant("function", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_function: %{{Sample, :run, 1} => MapSet.new([{:file, "test/function_test.exs"}])}
    }

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["function"] == %{
             test_files: ["test/function_test.exs"],
             match_kind: :enclosing_function
           }
  end

  test "falls back to static selection" do
    plan = plan([mutant("static", "lib/sample.ex", 10, Sample, {:run, 1})])
    oracle = %CoverageOracle{}

    result = Coverage.for_plan(plan, oracle, %{Sample => MapSet.new(["test/static_test.exs"])})

    assert result["static"] == %{
             test_files: ["test/static_test.exs"],
             match_kind: :static_fallback
           }
  end

  test "falls back to all tests as final safety net" do
    plan = plan([mutant("all", "lib/sample.ex", 10, Sample, {:run, 1})])
    oracle = %CoverageOracle{}

    result =
      Coverage.for_plan(plan, oracle, %{}, all_test_files: ["test/a_test.exs", "test/b_test.exs"])

    assert result["all"] == %{
             test_files: ["test/a_test.exs", "test/b_test.exs"],
             match_kind: :all_tests
           }
  end

  test "orders selected tests by last killer, convention, runtime, and path" do
    plan = plan([mutant("ordered", "lib/sample.ex", 10, Sample, {:run, 1})])

    oracle = %CoverageOracle{
      by_line: %{
        {"lib/sample.ex", 10} =>
          MapSet.new([
            {:file, "test/z_slow_test.exs"},
            {:file, "test/sample_test.exs"},
            {:file, "test/a_fast_test.exs"},
            {:file, "test/b_fast_test.exs"}
          ])
      },
      test_runtime_ms: %{
        {:file, "test/z_slow_test.exs"} => 5,
        {:file, "test/a_fast_test.exs"} => 10,
        {:file, "test/b_fast_test.exs"} => 10,
        {:file, "test/sample_test.exs"} => 999
      }
    }

    {:ok, killer} = Mut.LastKiller.start_link([])
    Mut.LastKiller.record_kill(killer, Sample, "test/z_slow_test.exs")

    result = Coverage.for_plan(plan, oracle, %{}, last_killer: killer)

    assert result["ordered"].test_files == [
             "test/z_slow_test.exs",
             "test/sample_test.exs",
             "test/a_fast_test.exs",
             "test/b_fast_test.exs"
           ]
  end

  describe "clause-head mutations (finding 3)" do
    # `def value(0), do: :zero` / `def value(_), do: :other`. :cover reports
    # line 2 only for zero_test and line 3 only for one_test. Mutating the
    # head's `0` to `1` reroutes `value(0)` to the second clause, so one_test
    # is a killing test even though it never covered line 2. Exact-line
    # coverage must not be allowed to drop it.
    @zero {:file, "test/zero_test.exs"}
    @one {:file, "test/one_test.exs"}

    defp clause_head_oracle(by_function) do
      %CoverageOracle{
        by_line: %{
          {"lib/astra_pattern.ex", 2} => MapSet.new([@zero]),
          {"lib/astra_pattern.ex", 3} => MapSet.new([@one])
        },
        by_function: by_function
      }
    end

    test "a pattern mutation widens to enclosing-function coverage" do
      plan =
        plan([
          mutant("pattern", "lib/astra_pattern.ex", 2, AstraPattern, {:value, 1},
            env_context: :match
          )
        ])

      oracle =
        clause_head_oracle(%{
          {AstraPattern, :value, 1} => MapSet.new([@zero, @one])
        })

      result = Coverage.for_plan(plan, oracle, %{})

      assert result["pattern"] == %{
               test_files: ["test/one_test.exs", "test/zero_test.exs"],
               match_kind: :enclosing_function
             }
    end

    test "a guard mutation widens to enclosing-function coverage" do
      plan =
        plan([
          mutant("guard", "lib/astra_pattern.ex", 2, AstraPattern, {:value, 1},
            env_context: :guard
          )
        ])

      oracle =
        clause_head_oracle(%{
          {AstraPattern, :value, 1} => MapSet.new([@zero, @one])
        })

      assert Coverage.for_plan(plan, oracle, %{})["guard"].match_kind == :enclosing_function
    end

    test "without function metadata a pattern mutation widens to file coverage" do
      # The generated pattern mutant in the reported reproduction carried
      # `function: nil`, so enclosing-function coverage was unavailable.
      plan =
        plan([
          mutant("pattern", "lib/astra_pattern.ex", 2, AstraPattern, nil, env_context: :match)
        ])

      result = Coverage.for_plan(plan, clause_head_oracle(%{}), %{})

      assert result["pattern"] == %{
               test_files: ["test/one_test.exs", "test/zero_test.exs"],
               match_kind: :enclosing_file
             }
    end

    test "an ordinary expression mutation still uses exact-line coverage" do
      plan = plan([mutant("expr", "lib/astra_pattern.ex", 2, AstraPattern, {:value, 1})])

      result =
        Coverage.for_plan(
          plan,
          clause_head_oracle(%{{AstraPattern, :value, 1} => MapSet.new([@zero, @one])}),
          %{}
        )

      assert result["expr"] == %{
               test_files: ["test/zero_test.exs"],
               match_kind: :exact_line
             }
    end

    test "a clause-head mutation with no coverage at all still reaches all tests" do
      plan =
        plan([mutant("pattern", "lib/other.ex", 2, Other, nil, env_context: :match)])

      result =
        Coverage.for_plan(plan, clause_head_oracle(%{}), %{},
          all_test_files: ["test/one_test.exs", "test/zero_test.exs"]
        )

      assert result["pattern"].match_kind == :all_tests
    end
  end

  test "finding 4: a degraded test file is selected even when static analysis misses it" do
    # Degraded oracle reproduction: direct_test's coverage was collected,
    # indirect_test's collection timed out. indirect_test only names the
    # facade, so the static index has no entry for AstraHelper pointing at it —
    # yet it is the only killing test. Unknown coverage must never be read as
    # proof of irrelevance.
    plan = plan([mutant("helper", "lib/astra_helper.ex", 2, AstraHelper, {:value, 1})])

    oracle = %CoverageOracle{
      by_line: %{
        {"lib/astra_helper.ex", 2} => MapSet.new([{:file, "test/direct_test.exs"}])
      },
      degraded_test_files: [{"test/indirect_test.exs", :coverage_test_timeout}]
    }

    result =
      Coverage.for_plan(plan, oracle, %{AstraHelper => MapSet.new(["test/direct_test.exs"])})

    assert Enum.sort(result["helper"].test_files) == [
             "test/direct_test.exs",
             "test/indirect_test.exs"
           ]
  end

  defp plan(mutants), do: %Plan{schema: mutants, fallback: [], skipped: []}

  defp mutant(stable_id, file, line, module, function, opts \\ []) do
    %Mutant{
      id: 1,
      stable_id: stable_id,
      engine: :schema,
      mutator: __MODULE__,
      mutator_name: "TestMutator",
      file: file,
      line: line,
      module: module,
      function: function,
      env_context: Keyword.get(opts, :env_context),
      original_ast: quote(do: a + b),
      mutated_ast: quote(do: a - b),
      description: "replace + with -"
    }
  end
end
