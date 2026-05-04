defmodule Mut.Coverage.Parser do
  @moduledoc "Normalizes `:cover.analyse/2` output into Mut.CoverageOracle maps."

  @spec parse(term, term, Mut.CoverageOracle.test_id(), Path.t()) ::
          {%{{Path.t(), pos_integer()} => MapSet.t(Mut.CoverageOracle.test_id())},
           %{{module(), atom(), arity()} => MapSet.t(Mut.CoverageOracle.test_id())}}
  def parse({line_status, line_entries}, {function_status, function_entries}, test_id, root)
      when line_status in [:ok, :result] and function_status in [:ok, :result] do
    parse_entries(line_entries, function_entries, test_id, root)
  end

  def parse({line_status, line_entries, _}, {function_status, function_entries, _}, test_id, root)
      when line_status in [:ok, :result] and function_status in [:ok, :result] do
    parse_entries(line_entries, function_entries, test_id, root)
  end

  def parse(_line_entries, _function_entries, _test_id, _root), do: {%{}, %{}}

  defp parse_entries(line_entries, function_entries, test_id, root) do
    by_line =
      line_entries
      |> Enum.flat_map(fn
        {{module, line}, {hits, _not_hits}} when hits > 0 ->
          case module_source(module, root) do
            nil -> []
            file -> [{{file, line}, MapSet.new([test_id])}]
          end

        _entry ->
          []
      end)
      |> merge_sets()

    by_function =
      function_entries
      |> Enum.flat_map(fn
        {{module, function, arity}, {hits, _not_hits}} when hits > 0 ->
          [{{module, function, arity}, MapSet.new([test_id])}]

        _entry ->
          []
      end)
      |> merge_sets()

    {by_line, by_function}
  end

  defp merge_sets(entries) do
    Enum.reduce(entries, %{}, fn {key, set}, acc ->
      Map.update(acc, key, set, &MapSet.union(&1, set))
    end)
  end

  defp module_source(module, root) do
    # Compile metadata is authoritative for unconventional layouts. Generated
    # modules may omit source info; those are ignored by the v1.5 oracle.
    source = module.module_info(:compile)[:source]

    if source do
      source
      |> List.to_string()
      |> Path.relative_to(root)
    end
  rescue
    UndefinedFunctionError -> nil
    ArgumentError -> nil
  end
end
