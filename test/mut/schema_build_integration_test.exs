defmodule Mut.SchemaBuildIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_instrument

  alias Mut.Mutator.Defaults
  alias Mut.Mutator.Test.AlwaysWrong

  @fixture_root Path.expand("test/fixtures/demo_app")

  test "build compiles demo_app schema snapshot" do
    plan = Mut.Orchestrator.plan(@fixture_root, Mut.FixtureOracleHelper.golden_oracle())

    assert {:ok, result} =
             Mut.SchemaBuild.build(plan,
               user_project_root: @fixture_root,
               run_id: "m7-happy",
               force: true,
               keep: true
             )

    on_exit(fn -> File.rm_rf!(result.work_copy_root) end)

    assert result.invalid_mutants == []
    assert result.plan.invalid == []
    assert length(result.plan.schema) == 30
    assert result.rollback_iterations == 0

    for beam <-
          ~w(Elixir.Arith.beam Elixir.Cmp.beam Elixir.Bool.beam Elixir.Attrs.beam Elixir.Guards.beam) do
      assert Map.has_key?(result.snapshot, "lib/demo_app/ebin/#{beam}")
    end
  end

  test "rollback invalidates AlwaysWrong mutants and keeps valid schema mutants" do
    plan = always_wrong_plan(["lib/bool.ex"])
    wrong_count = Enum.count(plan.schema, &(&1.mutator == Mut.Mutator.Test.AlwaysWrong))

    assert {:ok, result} =
             Mut.SchemaBuild.build(plan,
               user_project_root: @fixture_root,
               run_id: "m7-always-wrong",
               force: true,
               keep: true,
               rollback: [max_iterations: 3]
             )

    on_exit(fn -> File.rm_rf!(result.work_copy_root) end)

    assert result.rollback_iterations in 1..3
    assert length(result.plan.invalid) == wrong_count
    assert length(result.invalid_mutants) == wrong_count
    assert Enum.all?(result.plan.invalid, &(&1.mutator == AlwaysWrong))

    assert Enum.all?(
             result.plan.invalid,
             &(is_binary(&1.compile_error) and &1.compile_error != "")
           )

    assert Enum.any?(result.plan.schema, &(&1.mutator != AlwaysWrong))
  end

  test "per-file budget exhaustion restores original source for that file" do
    plan = always_wrong_plan(["lib/arith.ex"])
    arith_original = File.read!(Path.join(@fixture_root, "lib/arith.ex"))
    arith_count = Enum.count(plan.schema, &(&1.file == "lib/arith.ex"))

    assert {:ok, result} =
             Mut.SchemaBuild.build(plan,
               user_project_root: @fixture_root,
               run_id: "m7-file-budget",
               force: true,
               keep: true,
               rollback: [max_iterations: 3, max_invalid_per_file: 0]
             )

    on_exit(fn -> File.rm_rf!(result.work_copy_root) end)

    assert File.read!(Path.join(result.work_copy_root, "lib/arith.ex")) == arith_original
    assert Enum.count(result.plan.invalid, &(&1.file == "lib/arith.ex")) == arith_count
    assert Enum.any?(result.plan.schema, &(&1.file != "lib/arith.ex"))
  end

  test "rollback iteration budget exhaustion is returned" do
    plan = always_wrong_plan(["lib/bool.ex"])

    assert {:error, {:schema_build_failed, {:rollback_budget_exhausted, details}}} =
             Mut.SchemaBuild.build(plan,
               user_project_root: @fixture_root,
               run_id: "m7-iteration-budget",
               force: true,
               rollback: [max_iterations: 0]
             )

    assert details.rollback_iterations == 0
  end

  test "user code compile failures are not converted to invalid mutants" do
    broken_root = Path.expand("tmp/m7_broken_demo_app")
    File.rm_rf!(broken_root)
    File.cp_r!(@fixture_root, broken_root)

    File.write!(
      Path.join(broken_root, "lib/broken.ex"),
      "defmodule Broken do\n  def nope(\nend\n"
    )

    on_exit(fn -> File.rm_rf!(broken_root) end)

    plan = Mut.Orchestrator.plan(@fixture_root, Mut.FixtureOracleHelper.golden_oracle())

    assert {:error, {:schema_build_failed, {:user_code_compile_failure, _diagnostic}}} =
             Mut.SchemaBuild.build(plan,
               user_project_root: broken_root,
               run_id: "m7-user-code-failure",
               force: true
             )
  end

  defp always_wrong_plan(files) do
    plan =
      Mut.Orchestrator.plan(@fixture_root, Mut.FixtureOracleHelper.golden_oracle(),
        mutators: Defaults.list() ++ [AlwaysWrong]
      )

    schema =
      Enum.reject(plan.schema, fn mutant ->
        mutant.mutator == AlwaysWrong and mutant.file not in files
      end)

    %{plan | schema: schema}
  end
end
