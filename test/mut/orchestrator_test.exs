defmodule Mut.OrchestratorTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.FixtureOracleHelper
  alias Mut.Oracle.DispatchSite

  @fixture_root Path.expand("test/fixtures/orchestrator")

  setup_all do
    path = Path.join(@fixture_root, "lib/sample.ex")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule Sample do
      @moduledoc false

      @some_const 42

      def f(x) when x > 0 do
        x + @some_const
      end
    end
    """)

    :ok
  end

  test "routes default v1 targets" do
    plan = Mut.Orchestrator.plan(@fixture_root, oracle(), files: ["lib/sample.ex"])

    assert length(plan.schema) == 2
    assert [] = plan.fallback
    assert skip_reasons(plan) == %{attribute_engine_disabled: 1, missing_oracle_site: 1}
  end

  test "enabled fallback targets produce attribute mutants" do
    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle(),
        files: ["lib/sample.ex"],
        enabled_targets: [:dispatch, :guard, :module_attribute]
      )

    assert length(plan.schema) == 2
    assert length(plan.fallback) == 2
    assert Enum.all?(plan.fallback, &(&1.mutator == Mut.Mutator.AttributeLiteral))
    assert Enum.all?(plan.fallback, &(&1.module == Sample))
    assert skip_reasons(plan) == %{missing_oracle_site: 1}
  end

  test "T02: dispatch mutants are gated on the :dispatch target" do
    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle(),
        files: ["lib/sample.ex"],
        enabled_targets: [:module_attribute]
      )

    assert [] = plan.schema
    assert Enum.all?(plan.fallback, &(&1.mutator == Mut.Mutator.AttributeLiteral))
    refute Map.has_key?(skip_reasons(plan), :unsupported_dispatch)
  end

  test "T02: --enable guard_boolean alone runs the guard walk without :guard mutators" do
    path = Path.join(@fixture_root, "lib/guarded.ex")

    File.write!(path, """
    defmodule Guarded do
      def g(x) when is_integer(x) and x > 0, do: x
    end
    """)

    on_exit(fn -> File.rm_rf!(path) end)

    src = File.read!(path)

    col = fn needle ->
      (src |> String.split("\n") |> Enum.at(1) |> :binary.match(needle) |> elem(0)) + 1
    end

    oracle =
      FixtureOracleHelper.oracle([
        %{
          site(2, col.("and"), :and, 2)
          | file: "lib/guarded.ex",
            dispatch_kind: :imported_macro,
            env_context: :guard
        },
        %{site(2, col.(">"), :>, 2) | file: "lib/guarded.ex", env_context: :guard}
      ])

    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle,
        files: ["lib/guarded.ex"],
        enabled_targets: [:guard_boolean],
        mutators: [Mut.Mutator.GuardBoolean, Mut.Mutator.GuardComparisonNegation]
      )

    assert [] = plan.schema
    assert plan.fallback != []
    assert Enum.all?(plan.fallback, &(&1.mutator == Mut.Mutator.GuardBoolean))
  end

  test "an unparsable file is skipped with a :parse_error diagnostic, not a crash (M118)" do
    bad = Path.join(@fixture_root, "lib/broken.ex")
    File.write!(bad, "defmodule Broken do def f( end\n")
    on_exit(fn -> File.rm_rf!(bad) end)

    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle(), files: ["lib/sample.ex", "lib/broken.ex"])

    # The good file still produced its mutants; the bad file is recorded as a skip.
    assert length(plan.schema) == 2
    assert Map.get(skip_reasons(plan), :parse_error) == 1
    assert Enum.any?(plan.skipped, &(&1.file == "lib/broken.ex" and &1.reason == :parse_error))
  end

  test "oracle-backed unsupported candidates are not reported as missing" do
    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle_with_unsupported_site(),
        files: ["lib/sample.ex"]
      )

    assert Enum.any?(
             plan.skipped,
             &(&1.reason == :unsupported_dispatch and &1.syntactic_name == :+)
           )
  end

  test "T13: @mutalisk_ignore true on a NESTED module suppresses its env-walker mutants" do
    path = Path.join(@fixture_root, "lib/nested.ex")
    on_exit(fn -> File.rm_rf!(path) end)

    plan_for = fn source ->
      File.write!(path, source)

      Mut.Orchestrator.plan(@fixture_root, FixtureOracleHelper.oracle([]),
        files: ["lib/nested.ex"],
        enabled_targets: [:env_walker],
        mutators: [Mut.Mutator.CollectionEmpty]
      )
    end

    baseline =
      plan_for.("""
      defmodule Outer do
        defmodule Inner do
          def items do
            [1, 2, 3]
          end
        end
      end
      """)

    # The candidate must be attributed to the FULLY-QUALIFIED nested module —
    # that is the name `AstWalk.ignored_modules/1` records, and
    # `apply_module_ignores/2` matches exactly.
    assert baseline.fallback != []
    assert Enum.all?(baseline.fallback, &(&1.module == Outer.Inner))

    ignored =
      plan_for.("""
      defmodule Outer do
        defmodule Inner do
          @mutalisk_ignore true

          def items do
            [1, 2, 3]
          end
        end
      end
      """)

    assert ignored.fallback == [], "nested-module mutants must be dropped by @mutalisk_ignore"

    assert Enum.count(ignored.skipped, &(&1.reason == :mutalisk_ignore)) ==
             length(baseline.fallback)
  end

  defp oracle do
    [
      site(7, 7, :+, 2),
      site(7, 11, :+, 2)
    ]
    |> FixtureOracleHelper.oracle()
  end

  defp oracle_with_unsupported_site do
    [site(7, 7, :defadd, 1)]
    |> FixtureOracleHelper.oracle()
  end

  defp site(line, column, name, arity) do
    %DispatchSite{
      file: "lib/sample.ex",
      line: line,
      column: column,
      dispatch_kind: :imported_function,
      resolved_module: Kernel,
      resolved_name: name,
      resolved_arity: arity,
      event_file: "lib/sample.ex",
      module: Sample,
      function: {:f, 1},
      env_context: nil,
      meta: [line: line, column: column]
    }
  end

  defp skip_reasons(plan), do: Enum.frequencies_by(plan.skipped, & &1.reason)
end
