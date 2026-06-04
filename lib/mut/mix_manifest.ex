defmodule Mut.MixManifest do
  @moduledoc "Reads pinned Mix Elixir compiler manifests for fallback recompilation."

  # Elixir 1.20.0 bumped the manifest version 34 -> 35 with a byte-identical
  # tuple shape (verified against a real v35 manifest: same 11-tuple outer,
  # `{:module, kind, [source], ...}` 6-tuple module records, `{:source, size,
  # mtime, digest, compile_refs, export_refs, runtime_refs, ...}` 12-tuple
  # source records, refs still module lists). 34 = 1.20-rc.4, 29 = 1.19.
  @supported_manifest_versions [29, 34, 35]

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
        {version, modules, sources, _exports, _parents, _cache_key, _cwd, _deps_config,
         _project_mtime, _config_mtime, _protocols_and_impls}
      )
      when version in @supported_manifest_versions and is_map(modules) and is_map(sources),
      do: :ok

  def version_assertion(term) do
    version = if is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0), else: :unknown

    raise ArgumentError,
          "unsupported Mix Elixir manifest shape/version #{inspect(version)}; " <>
            "Mut.MixManifest supports manifest versions #{inspect(@supported_manifest_versions)}"
  end

  @doc """
  Reads and merges every umbrella app's manifest into one cross-app graph
  (M68). Each app's source paths are prefixed with `apps/<app>/` so they are
  globally unique and root-relative (matching mutant file paths); module
  references inside the dep lists are global identifiers and stay unprefixed,
  so `dependents/3` on the merged manifest spans app boundaries — a module
  mutated in app A yields dependent source files in app B.
  """
  @spec read_combined([{String.t(), Path.t()}]) :: {:ok, t} | {:error, term}
  def read_combined(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %__MODULE__{}}, fn {app, path}, {:ok, acc} ->
      case read(path) do
        {:ok, manifest} -> {:cont, {:ok, merge(acc, prefix_sources(manifest, app))}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prefix_sources(%__MODULE__{} = m, app) do
    prefix = fn source -> Path.join(["apps", app, source]) end

    %__MODULE__{
      version: m.version,
      modules: Map.new(m.modules, fn {mod, source} -> {mod, prefix.(source)} end),
      sources: Map.new(m.sources, fn {source, deps} -> {prefix.(source), deps} end)
    }
  end

  defp merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    # `b` is always a freshly-read manifest, so its version is authoritative.
    %__MODULE__{
      version: b.version,
      modules: Map.merge(a.modules, b.modules),
      sources: Map.merge(a.sources, b.sources)
    }
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

    {version, module_records, source_records, _exports, _parents, _cache_key, _cwd, _deps_config,
     _project_mtime, _config_mtime, _protocols_and_impls} = term

    %__MODULE__{
      version: version,
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
