defmodule Mut.TestSelection do
  @moduledoc "Selects test files for mutants."

  @dialyzer {:no_opaque, for_plan: 2}

  alias Mut.TestSelection.Static

  @spec for_plan(Mut.Plan.t(), [Path.t()]) :: %{Mut.Mutant.stable_id() => [Path.t()]}
  def for_plan(%Mut.Plan{} = plan, test_paths) when is_list(test_paths) do
    analysis = Static.analyze(test_paths)
    all_test_files = discover_test_files(test_paths)

    for mutant <- plan.schema ++ plan.fallback, into: %{} do
      tests = Static.covering_tests(analysis, mutant.module, all_test_files)
      {mutant.stable_id, tests}
    end
  end

  @spec discover_test_files([Path.t()]) :: [Path.t()]
  def discover_test_files(test_paths) when is_list(test_paths) do
    test_paths
    |> Enum.flat_map(fn path -> path |> Path.join("**/*_test.exs") |> Path.wildcard() end)
    |> Enum.sort()
  end
end
