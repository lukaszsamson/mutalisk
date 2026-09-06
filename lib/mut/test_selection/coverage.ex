defmodule Mut.TestSelection.Coverage do
  @moduledoc "Selects tests for mutants using the v1.5 coverage oracle."

  alias Mut.CoverageOracle
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.TestSelection.Static

  @type match_kind ::
          :exact_line | :enclosing_function | :enclosing_file | :static_fallback | :all_tests
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
      mutant
      |> selection_ladder(oracle, analysis, all_test_files)
      |> Enum.find_value(fn {kind, produce} ->
        case produce.() do
          [] -> nil
          tests -> %{test_files: tests, match_kind: kind}
        end
      end)
      |> Kernel.||(%{test_files: all_test_files, match_kind: :all_tests})

    # The selection may mix namespaces: oracle by_line/by_function tests are
    # relative-to-root, while static/all_tests selections are absolute. The
    # worker relativizes either form so verdicts are unchanged, but mixed
    # paths weaken the last-killer / runtime ordering heuristics and muddy the
    # selection metrics. Canonicalize to the oracle's relative-to-root
    # namespace so ordering, the degraded union below, and metrics all compare
    # like with like. (`match_kind` is already fixed above, so this does not
    # affect classification.)
    files = normalize_test_files(base.test_files, root)

    # Degraded coverage is UNKNOWN coverage, not evidence of irrelevance: a
    # test whose coverage collection timed out or failed may well exercise this
    # mutant. Union every degraded file in unconditionally (the `degraded` list
    # is already relative-to-root) so degradation can never cause a false
    # survivor. Previously this intersected the degraded set with the (static,
    # incomplete) covering set, which dropped exactly the tests it was meant to
    # rescue.
    %{base | test_files: Enum.uniq(files ++ degraded)}
  end

  # Ordered selection strategies; the first that yields a non-empty test set
  # wins, and the pair's key becomes the reported `match_kind`. Falls through
  # to `:all_tests`.
  #
  # Clause-head mutations (`:match` patterns, `:guard`) are the exception to
  # exact-line coverage: mutating a clause head can make that clause accept
  # inputs that originally routed to a DIFFERENT clause, so the killing test
  # need never have executed the mutated line. Those mutants start at
  # enclosing-function scope (every clause of the function) and, when function
  # metadata is unavailable, at whole-file scope. Exact-line coverage is never
  # allowed to narrow them.
  defp selection_ladder(mutant, oracle, analysis, all_test_files) do
    exact_line =
      if clause_head_mutation?(mutant),
        do: [],
        else: [
          {:exact_line, fn -> oracle_tests(oracle.by_line, {mutant.file, mutant.line}) end}
        ]

    enclosing_file =
      if clause_head_mutation?(mutant),
        do: [{:enclosing_file, fn -> file_tests(mutant, oracle) end}],
        else: []

    exact_line ++
      [{:enclosing_function, fn -> function_tests(mutant, oracle) end}] ++
      enclosing_file ++
      [{:static_fallback, fn -> static_tests(analysis, mutant, all_test_files) end}]
  end

  defp clause_head_mutation?(%Mutant{env_context: context}), do: context in [:match, :guard]

  # Every test that covers ANY line of the mutant's file.
  defp file_tests(%Mutant{file: file}, oracle) when is_binary(file) do
    oracle.by_line
    |> Enum.reduce(MapSet.new(), fn
      {{^file, _line}, tests}, acc -> MapSet.union(acc, tests)
      _entry, acc -> acc
    end)
    |> test_ids_to_files()
  end

  defp file_tests(_mutant, _oracle), do: []

  defp normalize_test_files(files, nil), do: files

  defp normalize_test_files(files, root) do
    files |> Enum.map(&Path.relative_to(&1, root)) |> Enum.uniq()
  end

  defp normalize_test_path(path, nil), do: path
  defp normalize_test_path(path, root), do: Path.relative_to(path, root)

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
    %{index: index, dynamic_dispatch_files: MapSet.new(), source_graph: %{}}
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
