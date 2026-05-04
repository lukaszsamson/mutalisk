defmodule Mut.TestSelection.Coverage do
  @moduledoc "Selects tests for mutants using the v1.5 coverage oracle."

  alias Mut.CoverageOracle
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.TestSelection.Static

  @type match_kind :: :exact_line | :enclosing_function | :static_fallback | :all_tests
  @type selection_result :: %{test_files: [Path.t()], match_kind: match_kind()}

  @spec for_plan(
          plan :: Plan.t(),
          oracle :: CoverageOracle.t(),
          static_index :: %{module() => MapSet.t(Path.t())} | Static.analysis(),
          opts :: keyword
        ) :: %{Mutant.stable_id() => selection_result()}
  def for_plan(%Plan{} = plan, %CoverageOracle{} = oracle, static_index, opts \\ [])
      when is_map(static_index) and is_list(opts) do
    all_test_files = Keyword.get(opts, :all_test_files, all_test_files(oracle, static_index))
    analysis = static_analysis(static_index)
    killer = Keyword.get(opts, :last_killer)

    for mutant <- plan.schema ++ plan.fallback, into: %{} do
      result = select(mutant, oracle, analysis, all_test_files)
      ordered = order_tests(result.test_files, mutant, oracle, killer)
      {mutant.stable_id, %{result | test_files: ordered}}
    end
  end

  @spec order_tests([Path.t()], Mutant.t(), CoverageOracle.t(), GenServer.server() | nil) :: [
          Path.t()
        ]
  def order_tests(test_files, %Mutant{} = mutant, %CoverageOracle{} = oracle, killer \\ nil)
      when is_list(test_files) do
    last_killer = last_killer(killer, mutant.module)

    Enum.sort_by(test_files, fn test_file ->
      {
        killer_priority(test_file, last_killer),
        convention_priority(test_file, mutant),
        runtime_ms(test_file, oracle),
        test_file
      }
    end)
  end

  defp select(%Mutant{} = mutant, oracle, analysis, all_test_files) do
    with [] <- oracle_tests(oracle.by_line, {mutant.file, mutant.line}),
         [] <- function_tests(mutant, oracle),
         [] <- static_tests(analysis, mutant, all_test_files) do
      %{test_files: all_test_files, match_kind: :all_tests}
    else
      tests when is_list(tests) ->
        %{
          test_files: tests,
          match_kind: match_kind(mutant, oracle, tests, analysis, all_test_files)
        }
    end
  end

  defp match_kind(mutant, oracle, tests, analysis, all_test_files) do
    cond do
      tests == oracle_tests(oracle.by_line, {mutant.file, mutant.line}) ->
        :exact_line

      tests == function_tests(mutant, oracle) ->
        :enclosing_function

      tests == static_tests(analysis, mutant, all_test_files) ->
        :static_fallback

      true ->
        :all_tests
    end
  end

  defp function_tests(%Mutant{module: module, function: {name, arity}}, oracle)
       when is_atom(module) and is_atom(name) and is_integer(arity) do
    oracle_tests(oracle.by_function, {module, name, arity})
  end

  defp function_tests(_mutant, _oracle), do: []

  defp static_tests(analysis, mutant, all_test_files) do
    selected = Static.covering_tests(analysis, mutant.module, all_test_files)

    cond do
      selected == [] -> []
      selected == all_test_files and not static_evidence?(analysis, mutant, selected) -> []
      true -> selected
    end
  end

  defp static_evidence?(analysis, %Mutant{module: module}, selected) when is_atom(module) do
    dynamic_hit? = not MapSet.disjoint?(analysis.dynamic_dispatch_files, MapSet.new(selected))

    indexed_hit? =
      analysis.index
      |> Enum.any?(fn {indexed_module, files} ->
        static_module_match?(indexed_module, module) and
          mapset_intersects?(files, selected)
      end)

    dynamic_hit? or indexed_hit? or convention_file?(selected, module)
  end

  defp static_evidence?(_analysis, _mutant, _selected), do: false

  defp static_module_match?(indexed_module, module) do
    indexed = Atom.to_string(indexed_module)
    target = Atom.to_string(module)

    indexed == target or String.starts_with?(target, indexed <> ".") or
      indexed == target <> "Test" or String.starts_with?(indexed, target <> "Test.")
  end

  defp convention_file?(selected, module), do: Enum.any?(selected, &convention_match?(&1, module))

  defp mapset_intersects?(files, selected) do
    Enum.any?(files, &(&1 in selected))
  end

  defp oracle_tests(index, key) do
    index
    |> Map.get(key, MapSet.new())
    |> test_ids_to_files()
  end

  defp test_ids_to_files(test_ids) do
    test_ids
    |> Enum.flat_map(fn
      {:file, file} when is_binary(file) -> [file]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp last_killer(nil, _module), do: nil
  defp last_killer(_killer, nil), do: nil
  defp last_killer(killer, module), do: Mut.LastKiller.lookup(killer, module)

  defp killer_priority(test_file, test_file), do: 0
  defp killer_priority(_test_file, _last_killer), do: 1

  defp convention_priority(test_file, %Mutant{module: module}) when is_atom(module) do
    if convention_match?(test_file, module), do: 0, else: 1
  end

  defp convention_priority(_test_file, _mutant), do: 1

  defp convention_match?(test_file, module) do
    parts = Enum.map(Module.split(module), &Macro.underscore/1)
    full_suffix = Path.join(parts) <> "_test.exs"
    leaf_suffix = List.last(parts) <> "_test.exs"

    String.ends_with?(test_file, full_suffix) or Path.basename(test_file) == leaf_suffix
  end

  defp runtime_ms(test_file, oracle) do
    Map.get(oracle.test_runtime_ms, {:file, test_file}, 999_999)
  end

  defp static_analysis(%{index: _index, dynamic_dispatch_files: _dynamic_files} = analysis),
    do: analysis

  defp static_analysis(index) do
    %{index: index, dynamic_dispatch_files: MapSet.new()}
  end

  defp all_test_files(oracle, static_index) do
    oracle_files =
      oracle
      |> oracle_file_sets()
      |> Enum.flat_map(&test_ids_to_files/1)

    static_files =
      static_index
      |> static_analysis()
      |> then(fn analysis ->
        analysis.index
        |> Map.values()
        |> Enum.flat_map(&MapSet.to_list/1)
        |> Kernel.++(MapSet.to_list(analysis.dynamic_dispatch_files))
      end)

    (oracle_files ++ static_files)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp oracle_file_sets(oracle) do
    Map.values(oracle.by_line) ++ Map.values(oracle.by_function)
  end
end
