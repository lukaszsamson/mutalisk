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
          if module_source(module, root) do
            [{{module, function, arity}, MapSet.new([test_id])}]
          else
            []
          end

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
    beam_module_source(module, root) || loaded_module_source(module, root)
  rescue
    UndefinedFunctionError -> nil
    ArgumentError -> nil
  end

  defp loaded_module_source(module, root) do
    module.module_info(:compile)[:source]
    |> source_relative_to(root)
  end

  defp beam_module_source(module, root) do
    root
    |> Path.join("_build/mut_coverage/lib/*/ebin/#{module}.beam")
    |> Path.wildcard()
    |> Enum.find_value(fn beam ->
      case :beam_lib.chunks(String.to_charlist(beam), [:compile_info]) do
        {:ok, {_module, [compile_info: compile_info]}} ->
          compile_info[:source] |> source_relative_to(root)

        _unknown ->
          nil
      end
    end)
  end

  defp source_relative_to(nil, _root), do: nil

  defp source_relative_to(source, root) do
    source = source |> List.to_string() |> Path.expand()
    root = Path.expand(root)

    if String.starts_with?(source, root <> "/") do
      Path.relative_to(source, root)
    end
  end
end
