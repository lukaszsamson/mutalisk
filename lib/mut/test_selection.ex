defmodule Mut.TestSelection do
  @moduledoc "Selects test files for mutants."

  @dialyzer {:no_opaque, for_plan: 2}

  alias Mut.TestSelection.Static

  @spec for_plan(Mut.Plan.t(), [Path.t()], keyword()) :: %{Mut.Mutant.stable_id() => [Path.t()]}
  def for_plan(%Mut.Plan{} = plan, test_paths, opts \\ [])
      when is_list(test_paths) and is_list(opts) do
    analysis = Static.analyze(test_paths, opts)
    all_test_files = discover_test_files(test_paths)

    for mutant <- plan.schema ++ plan.fallback, into: %{} do
      tests = Static.covering_tests(analysis, mutant.module, all_test_files)
      {mutant.stable_id, tests}
    end
  end

  @spec discover_test_files([Path.t()]) :: [Path.t()]
  def discover_test_files(test_paths) when is_list(test_paths) do
    test_paths
    |> Enum.flat_map(&discover_path/1)
    |> Enum.sort()
  end

  defp discover_path(path) do
    if File.regular?(path) and String.ends_with?(path, "_test.exs") do
      [path]
    else
      path |> Path.join("**/*_test.exs") |> Path.wildcard()
    end
  end
end
