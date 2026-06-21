defmodule Mut.TestSelection.Static do
  @moduledoc "Static test dependency analyzer."

  @dialyzer {:no_opaque, covering_tests: 3}

  @type ref_kind ::
          :alias
          | :import
          | :require
          | :use
          | :behaviour
          | :remote_call
          | :capture
          | :literal_apply

  @type index :: %{module() => MapSet.t(Path.t())}
  @type analysis :: %{index: index(), dynamic_dispatch_files: MapSet.t(Path.t())}

  @spec analyze(test_paths :: [Path.t()]) :: analysis()
  def analyze(test_paths) when is_list(test_paths) do
    test_paths
    |> discover_test_files()
    |> Enum.reduce(%{index: %{}, dynamic_dispatch_files: MapSet.new()}, &analyze_file/2)
  end

  @spec covering_tests(analysis(), module() | nil, [Path.t()]) :: [Path.t()]
  def covering_tests(
        %{index: _index, dynamic_dispatch_files: _dynamic_files},
        nil,
        all_test_files
      )
      when is_list(all_test_files) do
    Enum.sort(all_test_files)
  end

  def covering_tests(
        %{index: index, dynamic_dispatch_files: dynamic_files},
        module,
        all_test_files
      )
      when is_atom(module) and is_list(all_test_files) do
    known_files = MapSet.new(all_test_files)

    selected =
      MapSet.new()
      |> union_indexed(index, module_prefixes(module))
      |> MapSet.union(suffix_convention_tests(index, module))
      |> MapSet.union(path_mirror_tests(module, known_files))
      |> MapSet.union(dynamic_files)
      |> MapSet.intersection(known_files)

    if MapSet.size(selected) == 0 do
      Enum.sort(all_test_files)
    else
      selected |> MapSet.to_list() |> Enum.sort()
    end
  end

  defp analyze_file(file, analysis) do
    # M118: an unparsable test file must not abort the whole run. Skipping its
    # analysis only drops that file's dispatch-index entries — the safe
    # direction (static selection over-selects, never silently under-selects).
    case Mut.SourceParse.parse(file) do
      {:ok, {ast, _source}} -> traverse(ast, analysis, file)
      {:error, _reason} -> analysis
    end
  end

  defp traverse(node, analysis, _file) when is_atom(node) or is_number(node) or is_binary(node),
    do: analysis

  defp traverse(node, analysis, file) do
    if quote_node?(node) do
      analysis
    else
      node
      |> record_node(analysis, file)
      |> then(fn analysis -> Enum.reduce(children(node), analysis, &traverse(&1, &2, file)) end)
    end
  end

  defp record_node(node, analysis, file) do
    cond do
      dynamic_dispatch?(node) ->
        put_dynamic(analysis, file)

      modules = grouped_alias_modules(node) ->
        Enum.reduce(modules, analysis, &put_reference(&2, &1, file))

      module = referenced_module(node) ->
        put_reference(analysis, module, file)

      true ->
        analysis
    end
  end

  # Grouped alias/import/require/use: `alias Foo.{Bar, Baz}` parses as a dotted
  # `Foo.{...}` node, NOT a plain `{:__aliases__, _, parts}`, so the
  # single-module `referenced_module/1` clauses miss it entirely — a test that
  # only references `Foo.Bar` via the grouped form would be dropped from the
  # mutant's selection and the mutant wrongly reported `:survived`. Expand each
  # branch (`Foo.Bar`, `Foo.Baz`) to a fully-qualified module.
  defp grouped_alias_modules(
         {op, _meta, [{{:., _dot, [{:__aliases__, _bm, base_parts}, :{}]}, _bmeta, branches}]}
       )
       when op in [:alias, :import, :require, :use] and is_list(branches) do
    modules =
      for {:__aliases__, _meta, suffix_parts} <- branches,
          module = safe_module_concat(base_parts ++ suffix_parts),
          not is_nil(module),
          do: module

    case modules do
      [] -> nil
      mods -> mods
    end
  end

  defp grouped_alias_modules(_node), do: nil

  defp referenced_module({:alias, _meta, [{:__aliases__, _alias_meta, parts} | _]}),
    do: safe_module_concat(parts)

  defp referenced_module({:import, _meta, [{:__aliases__, _alias_meta, parts} | _]}),
    do: safe_module_concat(parts)

  defp referenced_module({:require, _meta, [{:__aliases__, _alias_meta, parts} | _]}),
    do: safe_module_concat(parts)

  defp referenced_module({:use, _meta, [{:__aliases__, _alias_meta, parts} | _]}),
    do: safe_module_concat(parts)

  defp referenced_module(
         {:@, _meta, [{:behaviour, _behaviour_meta, [{:__aliases__, _alias_meta, parts}]}]}
       ),
       do: safe_module_concat(parts)

  defp referenced_module({:defmodule, _meta, [{:__aliases__, _alias_meta, parts} | _]}),
    do: safe_module_concat(parts)

  defp referenced_module({:apply, _meta, [{:__aliases__, _alias_meta, parts}, _name, _args]}),
    do: safe_module_concat(parts)

  defp referenced_module(
         {{:., _dot_meta, [{:__aliases__, _kernel_meta, [:Kernel]}, :apply]}, _meta,
          [{:__aliases__, _alias_meta, parts}, _name, _args]}
       ),
       do: safe_module_concat(parts)

  defp referenced_module(
         {{:., _dot_meta, [:erlang, :apply]}, _meta,
          [{:__aliases__, _alias_meta, parts}, _name, _args]}
       ),
       do: safe_module_concat(parts)

  defp referenced_module(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, _name]}, _meta, _args}
       ),
       do: safe_module_concat(parts)

  defp referenced_module(
         {:&, _meta,
          [
            {:/, _slash_meta,
             [
               {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, _name]}, _call_meta, _args},
               _arity
             ]}
          ]}
       ),
       do: safe_module_concat(parts)

  defp referenced_module(_node), do: nil

  defp dynamic_dispatch?({:apply, _meta, [{_var_name, _var_meta, ctx}, _name, _args]})
       when is_atom(ctx),
       do: true

  defp dynamic_dispatch?({:apply, _meta, [module, _fun, {_var_name, _var_meta, ctx}]})
       when is_atom(ctx),
       do: not literal_module?(module)

  defp dynamic_dispatch?(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Module]}, :concat]}, _meta, _args}
       ),
       do: true

  defp dynamic_dispatch?({{:., _dot_meta, [{_var_name, _var_meta, ctx}, _name]}, _meta, _args})
       when is_atom(ctx),
       do: true

  defp dynamic_dispatch?(_node), do: false

  defp quote_node?({:quote, _meta, _args}), do: true
  defp quote_node?(_node), do: false

  defp children(node) when is_list(node), do: node
  defp children(node) when is_tuple(node), do: Tuple.to_list(node)
  defp children(_node), do: []

  defp literal_module?({:__aliases__, _meta, _parts}), do: true
  defp literal_module?(_module), do: false

  defp put_reference(analysis, module, file) do
    update_in(analysis.index, fn index ->
      Map.update(index, module, MapSet.new([file]), &MapSet.put(&1, file))
    end)
  end

  defp put_dynamic(analysis, file) do
    update_in(analysis.dynamic_dispatch_files, &MapSet.put(&1, file))
  end

  defp union_indexed(selected, index, modules) do
    Enum.reduce(modules, selected, fn module, acc ->
      MapSet.union(acc, Map.get(index, module, MapSet.new()))
    end)
  end

  defp module_prefixes(module) do
    parts = Module.split(module)

    parts
    |> Enum.with_index(1)
    |> Enum.map(fn {_part, count} -> parts |> Enum.take(count) |> module_concat() end)
  end

  # `__aliases__` parts are normally atoms (`[:Foo, :Bar]`), but the AST
  # also admits dynamic parts:
  #
  #   * `__MODULE__.Foo` -> [{:__MODULE__, _, _}, :Foo]
  #   * `unquote(x).Foo` -> [{:unquote, _, [_]}, :Foo]
  #
  # These cannot be resolved statically. Calling `Module.concat` on them
  # via `to_string/1` raises `Protocol.UndefinedError` from
  # `String.Chars.impl_for!/1`. Treat any non-literal-part list as
  # dynamic dispatch (return nil); the caller already records dynamic
  # files separately.
  defp safe_module_concat(parts) do
    if Enum.all?(parts, &literal_alias_part?/1) do
      module_concat(parts)
    else
      nil
    end
  end

  defp literal_alias_part?(part) when is_atom(part) or is_binary(part), do: true
  defp literal_alias_part?(_other), do: false

  defp suffix_convention_tests(index, module) do
    target = Atom.to_string(module)

    Enum.reduce(index, MapSet.new(), fn {indexed_module, files}, acc ->
      indexed = Atom.to_string(indexed_module)

      if indexed == target <> "Test" or String.starts_with?(indexed, target <> "Test.") do
        MapSet.union(acc, files)
      else
        acc
      end
    end)
  end

  defp path_mirror_tests(module, all_test_files) do
    suffix =
      module
      |> Module.split()
      |> Enum.map_join("/", &Macro.underscore/1)
      |> Kernel.<>("_test.exs")

    all_test_files
    |> Enum.filter(
      &(Path.basename(&1) == Path.basename(suffix) and String.ends_with?(&1, suffix))
    )
    |> MapSet.new()
  end

  defp discover_test_files(test_paths) do
    test_paths
    |> Enum.flat_map(fn path -> path |> Path.join("**/*_test.exs") |> Path.wildcard() end)
    |> Enum.sort()
  end

  defp module_concat(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Module.concat()
  end
end
