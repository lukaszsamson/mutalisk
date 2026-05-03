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
    assert skip_reasons(plan) == %{attribute_engine_disabled: 1, guard_engine_disabled: 1}
  end

  test "enabled fallback targets skip when no fallback mutators exist" do
    plan =
      Mut.Orchestrator.plan(@fixture_root, oracle(),
        files: ["lib/sample.ex"],
        enabled_targets: [:dispatch, :guard, :module_attribute]
      )

    assert length(plan.schema) == 2
    assert [] = plan.fallback
    assert skip_reasons(plan) == %{no_applicable_mutator: 2}
  end

  defp oracle do
    [
      site(7, 7, :+, 2),
      site(7, 11, :+, 2)
    ]
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
