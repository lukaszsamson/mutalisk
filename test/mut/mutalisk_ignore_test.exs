defmodule Mut.MutaliskIgnoreTest do
  use ExUnit.Case, async: false

  @moduledoc "M100: @mutalisk_ignore true excludes a module's mutants."

  alias Mut.AstWalk

  defp ast(src), do: Code.string_to_quoted!(src, columns: true, token_metadata: true)

  describe "AstWalk.ignored_modules/1" do
    test "detects a module-level @mutalisk_ignore true" do
      src = """
      defmodule Ignored do
        @mutalisk_ignore true
        def f(x), do: x + 1
      end

      defmodule Kept do
        def g(x), do: x - 1
      end
      """

      assert AstWalk.ignored_modules(ast(src)) == MapSet.new([Ignored])
    end

    test "ignores only the module that carries the attribute, including nesting" do
      src = """
      defmodule Outer do
        def a(x), do: x + 1

        defmodule Inner do
          @mutalisk_ignore true
          def b(x), do: x - 1
        end
      end
      """

      # The attribute is Inner's; it must not leak to Outer.
      assert AstWalk.ignored_modules(ast(src)) == MapSet.new([Outer.Inner])
    end

    test "@mutalisk_ignore false (or absent) does not ignore" do
      src = """
      defmodule A do
        @mutalisk_ignore false
        def f(x), do: x + 1
      end

      defmodule B do
        def g(x), do: x - 1
      end
      """

      assert AstWalk.ignored_modules(ast(src)) == MapSet.new()
    end
  end

  describe "end-to-end: plan excludes an ignored module" do
    @fixture_root Path.expand("test/fixtures/demo_app")

    @tag :golden_oracle
    test "marking a module @mutalisk_ignore removes its mutants (recorded as skips)" do
      tmp =
        Path.expand("tmp/tests/mutalisk_ignore/demo_app_#{System.unique_integer([:positive])}")

      File.rm_rf!(tmp)
      File.mkdir_p!(Path.dirname(tmp))
      File.cp_r!(@fixture_root, tmp)
      File.rm_rf!(Path.join(tmp, "_build"))
      File.rm_rf!(Path.join(tmp, "deps"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      # Baseline plan (no ignores) — Arith contributes mutants.
      {:ok, oracle} = Mut.OracleBuild.run(tmp, run_id: "ignore-baseline", force: true)
      baseline = Mut.Orchestrator.plan(tmp, oracle)

      arith_baseline =
        (baseline.schema ++ baseline.fallback) |> Enum.count(&(&1.module == Arith))

      assert arith_baseline > 0, "expected Arith to contribute mutants in the baseline"

      # Mark Arith with @mutalisk_ignore true and re-plan.
      arith = Path.join(tmp, "lib/arith.ex")

      File.write!(
        arith,
        String.replace(
          File.read!(arith),
          ~s(@moduledoc "Fixture arithmetic module."),
          ~s(@moduledoc "Fixture arithmetic module."\n  @mutalisk_ignore true)
        )
      )

      {:ok, oracle2} = Mut.OracleBuild.run(tmp, run_id: "ignore-marked", force: true)
      ignored_plan = Mut.Orchestrator.plan(tmp, oracle2)

      refute Enum.any?(ignored_plan.schema ++ ignored_plan.fallback, &(&1.module == Arith)),
             "Arith mutants must be removed when the module is @mutalisk_ignore true"

      assert Enum.count(ignored_plan.skipped, &(&1.reason == :mutalisk_ignore)) >= arith_baseline,
             "removed Arith mutants should be recorded as :mutalisk_ignore skips"
    end
  end
end
