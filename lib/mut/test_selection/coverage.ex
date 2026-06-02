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
    killer = Keyword.get(opts, :last_killer)
    root = Keyword.get(opts, :root)
    base = base_for_plan(plan, oracle, static_index, opts)

    for mutant <- plan.schema ++ plan.fallback, into: %{} do
      result = Map.fetch!(base, mutant.stable_id)
      ordered = order_tests(result.test_files, mutant, oracle, killer, root)
      {mutant.stable_id, %{result | test_files: ordered}}
    end
  end

  @doc """
  Per-mutant base test selection WITHOUT last-killer ordering. The base
  membership (which tests cover/statically-match each mutant) is independent
  of `last_killer`; only `order_tests/4` reads the live last-killer state.
  Callers that run many mutants precompute this once and apply `order_tests/4`
  per mutant, turning an O(N^2) whole-plan recompute into O(N) base + O(1)
  lookup. `for_plan/4` is `base_for_plan/4` + per-mutant ordering.
  """
  @spec base_for_plan(Plan.t(), CoverageOracle.t(), map(), keyword()) :: %{
          optional(String.t()) => map()
        }
  def base_for_plan(%Plan{} = plan, %CoverageOracle{} = oracle, static_index, opts \\ [])
      when is_map(static_index) and is_list(opts) do
    all_test_files = Keyword.get(opts, :all_test_files, all_test_files(oracle, static_index))
    analysis = static_analysis(static_index)
    degraded = degraded_files(oracle)
    # Work-copy root, used to canonicalize test paths to the oracle's
    # relative-to-root namespace for the degraded-coverage union. nil in unit
    # tests that pass everything in one namespace already.
    root = Keyword.get(opts, :root)

    for mutant <- plan.schema ++ plan.fallback, into: %{} do
      {mutant.stable_id, select(mutant, oracle, analysis, all_test_files, degraded, root)}
    end
  end

  defp degraded_files(%CoverageOracle{degraded_test_files: files}) when is_list(files),
    do: Enum.map(files, fn {path, _reason} -> path end)

  defp degraded_files(_oracle), do: []

  @spec order_tests(
          [Path.t()],
          Mutant.t(),
          CoverageOracle.t(),
          GenServer.server() | nil,
          Path.t() | nil
        ) :: [Path.t()]
  def order_tests(
        test_files,
        %Mutant{} = mutant,
        %CoverageOracle{} = oracle,
        killer \\ nil,
        root \\ nil
      )
      when is_list(test_files) do
    last_killer = last_killer(killer, mutant.module)

    Enum.sort_by(test_files, fn test_file ->
      {
        killer_priority(test_file, last_killer),
        convention_priority(test_file, mutant),
        runtime_ms(test_file, oracle, root),
        test_file
      }
    end)
  end

  defp select(%Mutant{} = mutant, oracle, analysis, all_test_files, degraded, root) do
    base =
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

    # M64: a degraded (coverage-failed) test file still runs for the mutants it
    # statically covers — union its static coverage so degradation never causes
    # a false survivor.
    case degraded_cover(mutant, analysis, all_test_files, degraded, root) do
      [] -> base
      extra -> %{base | test_files: Enum.uniq(base.test_files ++ extra)}
    end
  end

  # Degraded files that have static evidence for this mutant — unioned into the
  # selection so a coverage-failed file still runs for the mutants it
  # statically covers (M64: degradation must never cause a false survivor).
  #
  # The degraded list is in the oracle's relative-to-root namespace, but
  # `analysis` is keyed by the absolute paths the orchestrator passes as
  # `all_test_files`. Previously this fed the relative `degraded` list to
  # `covering_tests` as its known-files set, so the intersection against the
  # absolute index was always empty and the union contributed nothing —
  # silently defeating the guarantee. Fix: compute the mutant's static
  # covering tests over the real (absolute) `all_test_files`, then keep only
  # those whose relative-to-root form is degraded.
  defp degraded_cover(_mutant, _analysis, _all_test_files, [], _root), do: []

  defp degraded_cover(%Mutant{module: module} = mutant, analysis, all_test_files, degraded, root)
       when is_atom(module) do
    covering = Static.covering_tests(analysis, module, all_test_files)

    cond do
      covering == [] ->
        []

      # No real static evidence — `covering_tests` fell back to "all files".
      # Don't union the whole degraded set onto an unrelated mutant.
      covering == Enum.sort(all_test_files) and not static_evidence?(analysis, mutant, covering) ->
        []

      true ->
        degraded_set = MapSet.new(degraded)
        Enum.filter(covering, &(normalize_test_path(&1, root) in degraded_set))
    end
  end

  defp degraded_cover(_mutant, _analysis, _all_test_files, _degraded, _root), do: []

  defp normalize_test_path(path, nil), do: path
  defp normalize_test_path(path, root), do: Path.relative_to(path, root)

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

  defp convention_priority(test_file, %Mutant{module: module}) do
    if convention_match?(test_file, module), do: 0, else: 1
  end

  defp convention_match?(_test_file, nil), do: false

  defp convention_match?(test_file, module) when is_atom(module) do
    parts = Enum.map(Module.split(module), &Macro.underscore/1)
    full_suffix = Path.join(parts) <> "_test.exs"
    leaf_suffix = List.last(parts) <> "_test.exs"

    String.ends_with?(test_file, full_suffix) or Path.basename(test_file) == leaf_suffix
  end

  defp runtime_ms(test_file, oracle, root) do
    # The oracle keys runtimes by the work-copy-relative test path; the
    # `test_file` here may be absolute (static/all-tests selections), so
    # canonicalize before lookup or the baseline-runtime tie-break is inert
    # (always the 999_999 sentinel).
    Map.get(oracle.test_runtime_ms, {:file, normalize_test_path(test_file, root)}, 999_999)
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
