defmodule Mut.Orchestrator do
  @moduledoc "Builds mutation plans from source ASTs and oracle sites."

  alias Mut.Context
  alias Mut.Mutant
  alias Mut.Mutator.Defaults
  alias Mut.Oracle
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite
  alias Mut.Plan

  @type target :: :dispatch | :guard | :module_attribute | :body_literal | :env_walker

  @spec plan(work_copy_root :: Path.t(), Oracle.t(), opts :: keyword) :: Plan.t()
  def plan(work_copy_root, %Oracle{} = oracle, opts \\ []) do
    mutators = Keyword.get(opts, :mutators, Defaults.list())
    enabled_targets = Keyword.get(opts, :enabled_targets, [:dispatch, :guard])

    # M40 commit 3: build the tracer-macro index once per plan so the
    # walker can resolve if/unless to Kernel.if/2 / Kernel.unless/2
    # with proof (M39 spec, OpaquePolicy.trusted_kernel_control_flow?/3).
    # `:env_walker` opt-in: when not in enabled_targets, no parsing or
    # walking happens (byte-identity gate is binding).
    macro_index =
      if :env_walker in enabled_targets do
        Mut.EnvOracle.build_macro_index(oracle.sites)
      else
        nil
      end

    work_copy_root
    |> files(opts)
    |> Enum.map(&process_file(work_copy_root, &1, oracle, mutators, enabled_targets, macro_index))
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

  defp process_file(root, relative_file, oracle, mutators, enabled_targets, macro_index) do
    path = Path.join(root, relative_file)
    {:ok, {ast, source}} = Mut.SourceParse.parse(path)

    guard_candidates = Mut.AstWalk.guard_candidates(ast, file: relative_file, source: source)

    dispatch_candidates =
      ast
      |> Mut.AstWalk.dispatch_candidates(file: relative_file, source: source)
      |> Enum.reject(&guard_candidate?/1)

    attribute_candidates =
      Mut.AstWalk.attribute_candidates(ast, file: relative_file, source: source)

    body_literal_candidates =
      Mut.AstWalk.body_literal_candidates(file: relative_file, source: source)

    {matched, diagnostics} = Mut.Match.attach(dispatch_candidates, oracle, mutators)

    {schema, dispatch_skips} = dispatch_results(matched, mutators, source)

    {attribute_fallback, attribute_skips} =
      attribute_fallback_results(attribute_candidates, enabled_targets, mutators, source)

    {guard_fallback, guard_skips} =
      guard_fallback_results(guard_candidates, oracle, enabled_targets, mutators, source)

    {body_literal_fallback, body_literal_skips} =
      body_literal_fallback_results(
        body_literal_candidates,
        enabled_targets,
        mutators,
        source
      )

    # M40 commit 3: env-walker fifth candidate source. Disabled
    # unless `:env_walker` is in enabled_targets. M40 commit 5 lands
    # the StringLiteral mutator that consumes env_snapshots; in
    # commit 3 the walker runs (when enabled) but produces no
    # fallback entries — only contributing to the `Mut.EnvOracle`
    # diagnostics histogram (commit 6).
    env_pairs =
      if :env_walker in enabled_targets do
        env_walker_candidates(path, relative_file, source, macro_index)
      else
        []
      end

    {env_fallback, env_skips} =
      env_walker_results(env_pairs, enabled_targets, mutators, source)

    %Plan{
      schema: schema,
      fallback: attribute_fallback ++ guard_fallback ++ body_literal_fallback ++ env_fallback,
      invalid: [],
      skipped:
        diagnostic_skips(diagnostics, oracle) ++
          dispatch_skips ++
          attribute_skips ++
          guard_skips ++
          body_literal_skips ++
          env_skips,
      matched_pairs: matched
    }
  end

  defp env_walker_candidates(_path, relative_file, source, macro_index) do
    case Mut.EnvWalker.parse_string(source, relative_file) do
      {:ok, encoded_ast} ->
        Mut.EnvWalker.collect_string_literal_candidates(encoded_ast,
          file: relative_file,
          source: source,
          macro_index: macro_index
        )

      _ ->
        []
    end
  end

  # M40 commit 5: env-walker fallback results. Candidates from
  # `Mut.EnvWalker.collect_string_literal_candidates/2` are routed
  # through the standard fallback mutant pipeline when the
  # `:env_walker` target is enabled. The candidate stream is
  # already filtered to body-literal-eligible snapshots; the
  # mutator's own `applicable?/2` enforces engine and shape
  # constraints defensively.
  defp env_walker_results([], _enabled_targets, _mutators, _source), do: {[], []}

  defp env_walker_results(pairs, enabled_targets, mutators, source) do
    if :env_walker in enabled_targets do
      candidates = Enum.map(pairs, fn {candidate, _snap} -> candidate end)
      enabled_fallback_results(candidates, :env_walker, nil, mutators, source)
    else
      {[], []}
    end
  end

  defp body_literal_fallback_results(candidates, enabled_targets, mutators, source) do
    if :body_literal in enabled_targets do
      enabled_fallback_results(candidates, :body_literal, nil, mutators, source)
    else
      {[], Enum.map(candidates, &skip(&1, :body_literal_engine_disabled, nil))}
    end
  end

  defp guard_candidate?(%AstCandidate{ast_path: path}) do
    Enum.any?(path, &match?({:elem, :when, 1}, &1))
  end

  defp dispatch_results(matched, mutators, source) do
    matched
    |> Enum.map(&dispatch_mutants(&1, mutators, source))
    |> Enum.reduce({[], []}, fn
      {:mutants, mutants}, {all_mutants, skips} -> {all_mutants ++ mutants, skips}
      {:skip, skip}, {all_mutants, skips} -> {all_mutants, skips ++ [skip]}
    end)
  end

  defp dispatch_mutants({%AstCandidate{} = candidate, %DispatchSite{} = site}, mutators, source) do
    ctx = dispatch_context(candidate, site)

    mutators
    |> Enum.filter(&(target?(&1, :dispatch) and &1.compatible?(candidate, site)))
    |> Enum.flat_map(fn mutator -> mutations(candidate, site, mutator, ctx, :schema, source) end)
    |> case do
      [] -> {:skip, skip(candidate, :unsupported_dispatch, dispatch_detail(site))}
      mutants -> {:mutants, mutants}
    end
  end

  defp attribute_fallback_results(candidates, enabled_targets, mutators, source) do
    if :module_attribute in enabled_targets do
      enabled_fallback_results(candidates, :module_attribute, nil, mutators, source)
    else
      {[], Enum.map(candidates, &skip(&1, :attribute_engine_disabled, nil))}
    end
  end

  defp guard_fallback_results(candidates, oracle, enabled_targets, mutators, source) do
    if :guard in enabled_targets do
      guard_mutators = Enum.filter(mutators, &target?(&1, :guard))
      guard_enabled_results(candidates, oracle, guard_mutators, source)
    else
      {[], Enum.map(candidates, &skip(&1, :guard_engine_disabled, nil))}
    end
  end

  defp guard_enabled_results(candidates, _oracle, [], _source),
    do: {[], Enum.map(candidates, &skip(&1, :no_applicable_mutator, nil))}

  defp guard_enabled_results(candidates, oracle, guard_mutators, source) do
    {matched, diagnostics} = Mut.Match.attach(candidates, oracle, guard_mutators)

    {fallback, skips} = enabled_fallback_results(matched, :guard, guard_mutators, source)

    {fallback, skips ++ diagnostic_skips(diagnostics, oracle)}
  end

  defp enabled_fallback_results(candidates, target, site, mutators, source) do
    target_mutators = Enum.filter(mutators, &target?(&1, target))

    candidates
    |> Enum.map(&pair_with_site(&1, site))
    |> enabled_fallback_results(target, target_mutators, source)
  end

  defp enabled_fallback_results(pairs, target, target_mutators, source) do
    pairs
    |> Enum.map(&fallback_result(&1, target, target_mutators, source))
    |> Enum.reduce({[], []}, fn
      {:mutants, mutants}, {all_mutants, skips} -> {all_mutants ++ mutants, skips}
      {:skip, skip}, {all_mutants, skips} -> {all_mutants, skips ++ [skip]}
    end)
  end

  defp fallback_result({candidate, site}, target, target_mutators, source) do
    ctx = fallback_context(candidate, site, target)

    mutants =
      Enum.flat_map(target_mutators, &mutations(candidate, site, &1, ctx, :fallback, source))

    if mutants == [],
      do: {:skip, skip(candidate, :no_applicable_mutator, nil)},
      else: {:mutants, mutants}
  end

  defp mutations(candidate, site, mutator, ctx, engine, source) do
    if mutator.applicable?(candidate.node, ctx) do
      candidate.node
      |> mutator.mutate(ctx)
      |> Enum.reject(&mutator.equivalent?/1)
      |> Enum.map(&mutant(candidate, site, mutator, &1, engine, ctx, source))
    else
      []
    end
  end

  defp mutant(candidate, site, mutator, mutation, engine, ctx, source) do
    %Mutant{
      id: 0,
      stable_id: "",
      engine: engine,
      mutator: mutator,
      mutator_name: mutator.name(),
      mutation_kind: mutation.mutation_kind,
      stable_id_kind: stable_id_kind(mutation),
      original_dispatch: original_dispatch(candidate, site, ctx.env_context),
      ast_path_hash: candidate.ast_path_hash,
      start_byte: start_byte(candidate.source_span),
      end_byte: end_byte(candidate.source_span),
      file: candidate.file,
      line: candidate.line,
      column: candidate.column,
      span: span_tuple(candidate.source_span),
      module: mutant_module(candidate, site),
      function: site && site.function,
      original_ast: mutation.original_ast,
      mutated_ast: mutation.mutated_ast,
      source_patch: nil,
      original_source: original_source(candidate.source_span, source),
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

  defp diagnostic_skips(diagnostics, oracle) do
    Enum.map(diagnostics, fn {reason, candidate, detail} ->
      reason = reclassified_reason(reason, candidate, oracle)
      skip(candidate, reason, detail)
    end)
  end

  defp stable_id_kind(mutation) do
    metadata =
      mutation.metadata
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    "#{mutation.mutation_kind}:#{metadata}"
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

  defp fallback_context(candidate, site, target) do
    %Context{
      oracle_site: site,
      enclosing_function: site && site.function,
      enclosing_module: (site && site.module) || candidate.enclosing_module,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: fallback_env_context(candidate, site, target),
      engine: :fallback
    }
  end

  defp fallback_env_context(candidate, site, :guard),
    do: (site && site.env_context) || candidate.env_context

  defp fallback_env_context(_candidate, _site, :module_attribute), do: nil
  defp fallback_env_context(_candidate, _site, :body_literal), do: nil

  defp pair_with_site({%AstCandidate{}, %DispatchSite{}} = pair, _site), do: pair
  defp pair_with_site(%AstCandidate{} = candidate, site), do: {candidate, site}

  defp reclassified_reason(:missing_oracle_site, candidate, %Oracle{} = oracle) do
    if Oracle.sites_at_line?(oracle, candidate.file, candidate.line),
      do: :unsupported_dispatch,
      else: :missing_oracle_site
  end

  defp reclassified_reason(reason, _candidate, _oracle), do: reason

  defp target?(mutator, target), do: target in mutator.targets()

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

  defp mutant_module(_candidate, %DispatchSite{} = site), do: site.module
  defp mutant_module(%AstCandidate{} = candidate, nil), do: candidate.enclosing_module

  defp span_tuple(nil), do: nil

  defp span_tuple(span) do
    {span.start_line, span.start_column, span.end_line, span.end_column}
  end

  defp start_byte(nil), do: nil
  defp start_byte(span), do: span.start_byte

  defp end_byte(nil), do: nil
  defp end_byte(span), do: span.end_byte

  defp original_source(nil, _source), do: nil

  defp original_source(%{start_byte: start_byte, end_byte: end_byte}, source) do
    if is_integer(start_byte) and is_integer(end_byte) and end_byte >= start_byte do
      binary_part(source, start_byte, end_byte - start_byte)
    else
      nil
    end
  end

  defp combine_results(plans) do
    %Plan{
      schema: Enum.flat_map(plans, & &1.schema),
      fallback: Enum.flat_map(plans, & &1.fallback),
      invalid: Enum.flat_map(plans, & &1.invalid),
      skipped: Enum.flat_map(plans, & &1.skipped),
      matched_pairs: Enum.flat_map(plans, & &1.matched_pairs)
    }
  end
end
