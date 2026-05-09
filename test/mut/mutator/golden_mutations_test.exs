defmodule Mut.Mutator.GoldenMutationsTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  alias Mut.Context
  alias Mut.Match.Registry
  alias Mut.Mutator.Defaults
  alias Mut.Oracle
  alias Mut.Oracle.DispatchSite

  @fixture_root Path.expand("test/fixtures/demo_app")
  @oracle_golden Path.expand("test/golden/oracle/demo_app.json")
  @mutation_golden_root Path.expand("test/golden/mutations")
  @fixture_files ~w(arith.ex cmp.ex bool.ex guards.ex attrs.ex)

  setup do
    Registry.clear()
    Defaults.register_all()

    on_exit(fn -> Registry.clear() end)
  end

  test "fixture schema mutation lists match golden files" do
    Enum.each(@fixture_files, fn file ->
      actual = mutation_entries(file)
      golden = Path.join(@mutation_golden_root, "#{Path.rootname(file)}.json")

      if System.get_env("MUT_REGOLD") == "1" do
        File.mkdir_p!(@mutation_golden_root)
        File.write!(golden, Mut.JSON.encode!(actual, pretty: true) <> "\n")
      end

      assert actual == Mut.JSON.decode!(File.read!(golden))
    end)
  end

  test "matched fixture candidates all produce dispatch mutations except fallback-only guard candidates" do
    assert [] = matched_zero_mutations() -- expected_guard_zero_mutations()
  end

  defp matched_zero_mutations do
    @fixture_files
    |> Enum.flat_map(fn file ->
      "lib/#{file}"
      |> matched_fixture_file()
      |> elem(0)
    end)
    |> Enum.reject(fn pair -> mutations_for_pair(pair) != [] end)
    |> Enum.map(fn {candidate, _site} ->
      %{file: candidate.file, line: candidate.line, syntactic_name: candidate.syntactic_name}
    end)
  end

  defp expected_guard_zero_mutations do
    [
      %{file: "lib/guards.ex", line: 4, syntactic_name: :is_integer},
      %{file: "lib/guards.ex", line: 4, syntactic_name: :>},
      %{file: "lib/guards.ex", line: 4, syntactic_name: :and}
    ]
  end

  defp mutation_entries("guards.ex") do
    "lib/guards.ex"
    |> fallback_fixture_file(:guard)
    |> Enum.flat_map(&fallback_mutations_for_candidate/1)
    |> Enum.sort_by(&sort_key/1)
  end

  defp mutation_entries("attrs.ex") do
    "lib/attrs.ex"
    |> fallback_fixture_file(:module_attribute)
    |> Enum.flat_map(&fallback_mutations_for_candidate/1)
    |> Enum.sort_by(&sort_key/1)
  end

  defp mutation_entries(file) do
    {matched, _diagnostics} = matched_fixture_file("lib/#{file}")

    matched
    |> Enum.flat_map(&mutations_for_pair/1)
    |> Enum.sort_by(&sort_key/1)
  end

  defp matched_fixture_file(relative_file) do
    path = Path.join(@fixture_root, relative_file)
    {:ok, {ast, source}} = Mut.SourceParse.parse(path)
    candidates = Mut.AstWalk.dispatch_candidates(ast, file: relative_file, source: source)

    Mut.Match.attach(candidates, golden_oracle())
  end

  defp fallback_fixture_file(relative_file, :guard) do
    path = Path.join(@fixture_root, relative_file)
    {:ok, {ast, source}} = Mut.SourceParse.parse(path)
    candidates = Mut.AstWalk.guard_candidates(ast, file: relative_file, source: source)

    {matched, _diagnostics} =
      candidates
      |> Enum.reject(&(&1.syntactic_name == :and))
      |> Mut.Match.attach(golden_oracle(), fallback_mutators(:guard))

    Enum.map(matched, fn {candidate, site} -> {candidate, site, :guard} end)
  end

  defp fallback_fixture_file(relative_file, :module_attribute) do
    path = Path.join(@fixture_root, relative_file)
    {:ok, {ast, source}} = Mut.SourceParse.parse(path)

    ast
    |> Mut.AstWalk.attribute_candidates(file: relative_file, source: source)
    |> Enum.map(fn candidate -> {candidate, nil, :module_attribute} end)
  end

  defp mutations_for_pair({candidate, site}) do
    context = context(candidate, site)

    Defaults.list()
    |> Enum.filter(&(:dispatch in &1.targets() and &1.compatible?(candidate, site)))
    |> Enum.flat_map(fn mutator ->
      candidate.node
      |> mutator.mutate(context)
      |> Enum.map(&entry(candidate, mutator, &1))
    end)
  end

  defp fallback_mutations_for_candidate({candidate, site, target}) do
    context = fallback_context(candidate, site, target)

    target
    |> fallback_mutators()
    |> Enum.flat_map(fn mutator ->
      candidate.node
      |> mutator.mutate(context)
      |> Enum.map(&entry(candidate, mutator, &1))
    end)
  end

  defp fallback_mutators(target) do
    Enum.filter(Defaults.list(), &(target in &1.targets()))
  end

  defp context(candidate, site) do
    %Context{
      oracle_site: site,
      enclosing_function: site.function,
      enclosing_module: site.module,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: site.env_context,
      engine: :schema
    }
  end

  defp fallback_context(candidate, site, :guard) do
    %Context{
      oracle_site: site,
      enclosing_function: site.function,
      enclosing_module: site.module,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: site.env_context || candidate.env_context,
      engine: :fallback
    }
  end

  defp fallback_context(candidate, nil, :module_attribute) do
    %Context{
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: nil,
      engine: :fallback
    }
  end

  defp entry(candidate, mutator, mutation) do
    %{
      "file" => candidate.file,
      "line" => candidate.line,
      "column" => candidate.column,
      "mutator" => mutator.name(),
      "kind" => Atom.to_string(mutation.mutation_kind),
      "description" => mutation.description,
      "guard_safe" => mutation.guard_safe?,
      "operator" => atom_string(Map.get(mutation.metadata, :operator)),
      "replacement" => atom_string(Map.get(mutation.metadata, :replacement)),
      "original_value" => inspect_or_nil(Map.get(mutation.metadata, :original_value)),
      "replacement_value" => inspect_or_nil(Map.get(mutation.metadata, :replacement_value))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sort_key(entry) do
    {entry["file"], entry["line"], entry["column"] || 0, entry["mutator"], entry["kind"],
     entry["description"]}
  end

  defp golden_oracle do
    @oracle_golden
    |> File.read!()
    |> Mut.JSON.decode!()
    |> Enum.map(&decode_site/1)
    |> oracle()
  end

  defp oracle(sites) do
    Enum.reduce(sites, %Oracle{}, fn site, store ->
      key = Oracle.primary_key(site)
      file_line = {site.file, site.line}

      %{
        store
        | sites: store.sites ++ [site],
          by_key: Map.update(store.by_key, key, [site], &(&1 ++ [site])),
          by_file_line: Map.update(store.by_file_line, file_line, [site], &(&1 ++ [site]))
      }
    end)
  end

  defp decode_site(map) do
    %DispatchSite{
      file: map["file"],
      line: map["line"],
      column: map["column"],
      end_line: map["end_line"],
      end_column: map["end_column"],
      env_context: decode_atom(map["env_context"]),
      module: decode_module(map["module"]),
      function: decode_function(map["function"]),
      dispatch_kind: decode_atom(map["dispatch_kind"]),
      resolved_module: decode_module(map["resolved_module"]),
      resolved_name: decode_atom(map["resolved_name"]),
      resolved_arity: map["resolved_arity"],
      event_file: map["event_file"],
      meta: Enum.map(map["meta"] || [], fn [key, value] -> {decode_atom(key), value} end)
    }
  end

  defp decode_function(nil), do: nil
  defp decode_function([name, arity]), do: {decode_atom(name), arity}

  defp decode_module(nil), do: nil
  defp decode_module(module), do: String.to_atom(module)

  defp decode_atom(nil), do: nil
  defp decode_atom(value) when is_binary(value), do: String.to_atom(value)

  defp atom_string(nil), do: nil
  defp atom_string(atom), do: Atom.to_string(atom)

  defp inspect_or_nil(nil), do: nil
  defp inspect_or_nil(value), do: inspect(value)
end
