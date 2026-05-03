defmodule Mut.MixManifest do
  @moduledoc "Reads pinned Mix Elixir compiler manifests for fallback recompilation."

  @manifest_vsn 34

  defstruct version: nil, modules: %{}, sources: %{}

  @type dep_kind :: :compile | :export | :struct | :runtime

  @type source_entry :: %{
          compile_deps: [module],
          export_deps: [module],
          struct_deps: [module],
          runtime_deps: [module]
        }

  @type t :: %__MODULE__{
          version: term,
          modules: %{module => Path.t()},
          sources: %{Path.t() => source_entry}
        }

  @spec read(Path.t()) :: {:ok, t} | {:error, term}
  def read(manifest_path) when is_binary(manifest_path) do
    term = manifest_path |> File.read!() |> :erlang.binary_to_term()

    {:ok, parse(term)}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @spec version_assertion(term) :: :ok
  def version_assertion(
        {@manifest_vsn, modules, sources, _exports, _parents, _cache_key, _cwd, _deps_config,
         _project_mtime, _config_mtime, _protocols_and_impls}
      )
      when is_map(modules) and is_map(sources),
      do: :ok

  def version_assertion(term) do
    version = if is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0), else: :unknown

    raise ArgumentError,
          "unsupported Mix Elixir manifest shape/version #{inspect(version)}; " <>
            "Mut.MixManifest is pinned to Elixir 1.20-rc.4 manifest version #{@manifest_vsn}"
  end

  @spec dependents(t, [module], [dep_kind]) :: MapSet.t(Path.t())
  def dependents(%__MODULE__{} = manifest, modules, kinds)
      when is_list(modules) and is_list(kinds) do
    input_sources = modules |> Enum.map(&Map.get(manifest.modules, &1)) |> Enum.reject(&is_nil/1)
    direct = direct_dependent_list(manifest, modules, kinds)

    compile =
      if :compile in kinds do
        compile_dependent_list(manifest, modules, [])
      else
        []
      end

    (direct ++ compile)
    |> Enum.uniq()
    |> reject_sources(input_sources)
    |> MapSet.new()
  end

  # Elixir 1.20-rc.4 writes:
  # {34, %{Module => {:module, kind, [source], export, recompile?, timestamp}},
  #      %{source => {:source, size, mtime, digest, compile_refs, export_refs,
  #                   runtime_refs, compile_env, external, compile_warnings,
  #                   runtime_warnings, modules}}, ...}
  # The real demo_app schema manifest was probed before pinning this parser. This
  # shape has export references but no distinct struct-reference slot, so
  # struct_deps intentionally mirrors export_deps for the v34 adapter.
  defp parse(term) do
    :ok = version_assertion(term)

    {@manifest_vsn, module_records, source_records, _exports, _parents, _cache_key, _cwd,
     _deps_config, _project_mtime, _config_mtime, _protocols_and_impls} = term

    %__MODULE__{
      version: @manifest_vsn,
      modules: module_sources(module_records),
      sources: sources(source_records)
    }
  end

  defp module_sources(module_records) do
    Map.new(module_records, fn {module,
                                {:module, _kind, [source | _rest], _export, _recompile?, _ts}} ->
      {module, source}
    end)
  end

  defp sources(source_records) do
    Map.new(source_records, fn
      {source,
       {:source, _size, _mtime, _digest, compile_refs, export_refs, runtime_refs, _compile_env,
        _external, _compile_warnings, _runtime_warnings, _modules}} ->
        {source,
         %{
           compile_deps: compile_refs,
           export_deps: export_refs,
           struct_deps: export_refs,
           runtime_deps: runtime_refs
         }}
    end)
  end

  defp direct_dependent_list(manifest, modules, kinds) do
    wanted = Map.new(modules, &{&1, true})

    manifest.sources
    |> Enum.filter(fn {_source, deps} -> direct_dep?(deps, wanted, kinds) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp direct_dep?(deps, modules, kinds) do
    kinds
    |> Enum.flat_map(&deps_for_kind(deps, &1))
    |> Enum.any?(&Map.has_key?(modules, &1))
  end

  defp compile_dependent_list(manifest, modules, seen_sources) do
    next_sources =
      manifest
      |> direct_dependent_list(modules, [:compile])
      |> Enum.reject(&(&1 in seen_sources))

    if next_sources == [] do
      seen_sources
    else
      next_modules = modules_for_sources(manifest, next_sources)

      compile_dependent_list(manifest, next_modules, Enum.uniq(seen_sources ++ next_sources))
    end
  end

  defp modules_for_sources(manifest, sources) do
    source_map = Map.new(sources, &{&1, true})

    manifest.modules
    |> Enum.filter(fn {_module, source} -> Map.has_key?(source_map, source) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp reject_sources(source_set, rejected_sources) do
    rejected = Map.new(rejected_sources, &{&1, true})

    Enum.reject(source_set, &Map.has_key?(rejected, &1))
  end

  defp deps_for_kind(deps, :compile), do: deps.compile_deps
  defp deps_for_kind(deps, :export), do: deps.export_deps
  defp deps_for_kind(deps, :struct), do: deps.struct_deps
  defp deps_for_kind(deps, :runtime), do: deps.runtime_deps
end
