defmodule Mut.Orchestrator do
  @moduledoc "Builds mutation plans from source ASTs and oracle sites."

  alias Mut.Context
  alias Mut.Mutant
  alias Mut.Mutator.Defaults
  alias Mut.Oracle
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite
  alias Mut.Plan

  @type target :: :dispatch | :guard | :module_attribute

  @spec plan(work_copy_root :: Path.t(), Oracle.t(), opts :: keyword) :: Plan.t()
  def plan(work_copy_root, %Oracle{} = oracle, opts \\ []) do
    mutators = Keyword.get(opts, :mutators, Defaults.list())
    enabled_targets = Keyword.get(opts, :enabled_targets, [:dispatch])

    work_copy_root
    |> files(opts)
    |> Enum.map(&process_file(work_copy_root, &1, oracle, mutators, enabled_targets))
    |> combine_results()
    |> Plan.finalize()
  end

  defp files(root, opts) do
    opts
    |> Keyword.get_lazy(:files, fn -> discover_files(root) end)
    |> Enum.reject(&filtered?(&1, Keyword.get(opts, :file_filter)))
    |> Enum.sort()
  end

  defp discover_files(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp filtered?(_file, nil), do: false
  defp filtered?(file, %Regex{} = regex), do: Regex.match?(regex, file)

  defp process_file(root, relative_file, oracle, mutators, enabled_targets) do
    path = Path.join(root, relative_file)
    {:ok, {ast, source}} = Mut.SourceParse.parse(path)

    guard_candidates = Mut.AstWalk.guard_candidates(ast, file: relative_file, source: source)

    dispatch_candidates =
      ast
      |> Mut.AstWalk.dispatch_candidates(file: relative_file, source: source)
      |> Enum.reject(&guard_candidate?/1)

    attribute_candidates =
      Mut.AstWalk.attribute_candidates(ast, file: relative_file, source: source)

    {matched, diagnostics} = Mut.Match.attach(dispatch_candidates, oracle, mutators)

    {schema, dispatch_skips} = dispatch_results(matched, mutators)

    %Plan{
      schema: schema,
      fallback: [],
      skipped:
        diagnostic_skips(diagnostics) ++
          dispatch_skips ++
          fallback_skips(attribute_candidates, :module_attribute, enabled_targets, mutators) ++
          fallback_skips(guard_candidates, :guard, enabled_targets, mutators),
      matched_pairs: Enum.map(matched, fn {candidate, site} -> {candidate, site} end)
    }
  end

  defp guard_candidate?(%AstCandidate{ast_path: path}) do
    Enum.any?(path, &match?({:elem, :when, 1}, &1))
  end

  defp dispatch_results(matched, mutators) do
    matched
    |> Enum.map(&dispatch_mutants(&1, mutators))
    |> Enum.reduce({[], []}, fn
      {:mutants, mutants}, {all_mutants, skips} -> {all_mutants ++ mutants, skips}
      {:skip, skip}, {all_mutants, skips} -> {all_mutants, skips ++ [skip]}
    end)
  end

  defp dispatch_mutants({%AstCandidate{} = candidate, %DispatchSite{} = site}, mutators) do
    ctx = dispatch_context(candidate, site)

    mutators
    |> Enum.filter(&(target?(&1, :dispatch) and &1.compatible?(candidate, site)))
    |> Enum.flat_map(fn mutator -> mutations(candidate, site, mutator, ctx, :schema) end)
    |> case do
      [] -> {:skip, skip(candidate, :unsupported_dispatch, dispatch_detail(site))}
      mutants -> {:mutants, mutants}
    end
  end

  defp fallback_skips(candidates, target, enabled_targets, mutators) do
    if target in enabled_targets do
      enabled_fallback_results(candidates, target, mutators)
    else
      Enum.map(candidates, &skip(&1, disabled_reason(target), nil))
    end
  end

  defp enabled_fallback_results(candidates, target, mutators) do
    target_mutators = Enum.filter(mutators, &target?(&1, target))

    Enum.flat_map(candidates, &fallback_result(&1, target, target_mutators))
  end

  defp fallback_result(candidate, target, target_mutators) do
    ctx = fallback_context(candidate, target)
    mutants = Enum.flat_map(target_mutators, &mutations(candidate, nil, &1, ctx, :fallback))

    if mutants == [], do: [skip(candidate, :no_applicable_mutator, nil)], else: mutants
  end

  defp mutations(candidate, site, mutator, ctx, engine) do
    if mutator.applicable?(candidate.node, ctx) do
      candidate.node
      |> mutator.mutate(ctx)
      |> Enum.reject(&mutator.equivalent?/1)
      |> Enum.map(&mutant(candidate, site, mutator, &1, engine, ctx))
    else
      []
    end
  end

  defp mutant(candidate, site, mutator, mutation, engine, ctx) do
    %Mutant{
      id: 0,
      stable_id: "",
      engine: engine,
      mutator: mutator,
      mutator_name: mutator.name(),
      mutation_kind: mutation.mutation_kind,
      original_dispatch: original_dispatch(candidate, site, ctx.env_context),
      ast_path_hash: candidate.ast_path_hash,
      start_byte: start_byte(candidate.source_span),
      end_byte: end_byte(candidate.source_span),
      file: candidate.file,
      line: candidate.line,
      column: candidate.column,
      span: span_tuple(candidate.source_span),
      module: site && site.module,
      function: site && site.function,
      original_ast: mutation.original_ast,
      mutated_ast: mutation.mutated_ast,
      source_patch: nil,
      original_source: nil,
      mutated_source: nil,
      description: mutation.description,
      status: :pending,
      skip_reason: nil,
      covering_tests: nil,
      killing_test: nil,
      duration_ms: nil,
      compile_error: nil
    }
  end

  defp diagnostic_skips(diagnostics) do
    Enum.map(diagnostics, fn {reason, candidate, detail} -> skip(candidate, reason, detail) end)
  end

  defp skip(%AstCandidate{} = candidate, reason, detail) do
    %{
      file: candidate.file,
      line: candidate.line,
      column: candidate.column,
      syntactic_name: candidate.syntactic_name,
      reason: reason,
      detail: detail
    }
  end

  defp dispatch_context(candidate, site) do
    %Context{
      oracle_site: site,
      enclosing_function: site.function,
      enclosing_module: site.module,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: site.env_context || candidate.env_context,
      engine: :schema
    }
  end

  defp fallback_context(candidate, target) do
    %Context{
      oracle_site: nil,
      enclosing_function: nil,
      enclosing_module: nil,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: fallback_env_context(candidate, target),
      engine: :fallback
    }
  end

  defp fallback_env_context(candidate, :guard), do: candidate.env_context
  defp fallback_env_context(_candidate, :module_attribute), do: nil

  defp target?(mutator, target), do: target in mutator.targets()

  defp disabled_reason(:guard), do: :guard_engine_disabled
  defp disabled_reason(:module_attribute), do: :attribute_engine_disabled

  defp dispatch_detail(site) do
    %{
      resolved_module: site.resolved_module,
      resolved_name: site.resolved_name,
      resolved_arity: site.resolved_arity
    }
  end

  defp original_dispatch(candidate, nil, :guard),
    do: "guard:" <> original_dispatch(candidate, nil, nil)

  defp original_dispatch(%AstCandidate{} = candidate, nil, _context),
    do: "@" <> Atom.to_string(candidate.syntactic_name)

  defp original_dispatch(_candidate, %DispatchSite{} = site, env_context) do
    prefix = if env_context == :guard, do: "guard:", else: ""
    prefix <> "#{inspect(site.resolved_module)}.#{site.resolved_name}/#{site.resolved_arity}"
  end

  defp span_tuple(nil), do: nil

  defp span_tuple(span) do
    {span.start_line, span.start_column, span.end_line, span.end_column}
  end

  defp start_byte(nil), do: nil
  defp start_byte(span), do: span.start_byte

  defp end_byte(nil), do: nil
  defp end_byte(span), do: span.end_byte

  defp combine_results(plans) do
    %Plan{
      schema: Enum.flat_map(plans, & &1.schema),
      fallback: Enum.flat_map(plans, & &1.fallback),
      skipped: Enum.flat_map(plans, & &1.skipped),
      matched_pairs: Enum.flat_map(plans, & &1.matched_pairs)
    }
  end
end
