defmodule Mut.Orchestrator do
  @moduledoc "Builds mutation plans from source ASTs and oracle sites."

  alias Mut.Context
  alias Mut.Mutant
  alias Mut.Mutator.Defaults
  alias Mut.Oracle
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite
  alias Mut.Plan

  @type target ::
          :dispatch
          | :guard
          | :module_attribute
          | :body_literal
          | :env_walker
          | :pattern_literal
          | :variable
          | :pattern_shape
          | :conditional
          | :statement_delete
          | :clause_delete
          | :guard_boolean
          | :pipeline_drop
          | :map_update_drop
          | :receive_timeout

  @spec plan(work_copy_root :: Path.t(), Oracle.t(), opts :: keyword) :: Plan.t()
  def plan(work_copy_root, %Oracle{} = oracle, opts \\ []) do
    mutators = Keyword.get(opts, :mutators, Defaults.list())
    enabled_targets = Keyword.get(opts, :enabled_targets, [:dispatch, :guard])

    # M40 commit 3: build the tracer-macro index once per plan so the
    # walker can resolve if/unless to Kernel.if/2 / Kernel.unless/2
    # with proof (M39 spec, OpaquePolicy.trusted_kernel_control_flow?/3).
    # Built for `:env_walker` (its literal/variable surfaces) and for
    # `:conditional` (the structural NegateConditional pass now gates its
    # `if`/`unless` candidates on the same tracer proof — a skip-only
    # cross-check that closes the Tier-3 trust gap). Absent for other plans,
    # so the byte-identity gate is unaffected.
    macro_index =
      if :env_walker in enabled_targets or :conditional in enabled_targets do
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
    # `:files` may be present-but-nil (the CLI default routes here), so fall to
    # discovery on nil — not just when the key is absent.
    (Keyword.get(opts, :files) || discover_files(root))
    |> Enum.reject(&filtered?(&1, Keyword.get(opts, :file_filter)))
    |> Enum.sort()
  end

  defp discover_files(root) do
    root
    |> source_globs()
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.uniq()
  end

  # Single-app: the project's own `lib/`. Umbrella: every child app's
  # `apps/<app>/lib/` (the root has no `lib/` of its own). M67.
  defp source_globs(root) do
    if Mut.Umbrella.umbrella?(root) do
      root
      |> Mut.Umbrella.app_dirs()
      |> Enum.map(&Path.join(&1, "lib/**/*.ex"))
    else
      [Path.join(root, "lib/**/*.ex")]
    end
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

    {matched, diagnostics} = Mut.Match.attach(dispatch_candidates, oracle, mutators)

    {dispatch_schema, dispatch_skips} = dispatch_results(matched, mutators, source)

    # M52: scalar body literals (integer/boolean/string/float/atom/nil)
    # carry plain-AST positional paths and route through the SCHEMA engine
    # (one instrumented build) instead of per-mutant fallback recompile.
    {literal_schema, literal_skips} =
      schema_literal_results(
        Mut.AstWalk.schema_literal_candidates(file: relative_file, source: source),
        enabled_targets,
        mutators,
        source
      )

    {attribute_fallback, attribute_skips} =
      attribute_fallback_results(attribute_candidates, enabled_targets, mutators, source)

    {guard_fallback, guard_skips} =
      guard_fallback_results(guard_candidates, oracle, enabled_targets, mutators, source)

    # Env walker contributes COLLECTION literals (list/tuple/map, body
    # position, M50) and — M53 — scalar literals in `:match` (pattern)
    # positions. Body scalars moved to the schema path above; both env-walker
    # streams stay fallback (collections and patterns cannot be schema-placed
    # cleanly). Parse once if either target is on; split by env_context.
    # Collect when env_walker/pattern_literal is on, OR when a graduated
    # pattern-literal mutator is active (M63: IntegerLiteral-in-pattern fires by
    # default, so its candidates must be discovered even without :env_walker).
    env_pairs =
      if :env_walker in enabled_targets or :pattern_literal in enabled_targets or
           graduated_pattern_active?(mutators) do
        env_walker_candidates(path, relative_file, source, macro_index)
      else
        []
      end

    {match_pairs, collection_pairs} =
      Enum.split_with(env_pairs, fn {candidate, _snap} -> candidate.env_context == :match end)

    {env_fallback, env_skips} =
      env_walker_results(collection_pairs, enabled_targets, mutators, source)

    {pattern_fallback, pattern_skips} =
      pattern_literal_results(match_pairs, enabled_targets, mutators, source)

    # M54: variable-reference mutators (opt-in `:variable` target), discovered
    # by a separate binding-scope-aware walk. Fallback-routed.
    {variable_fallback, variable_skips} =
      variable_results(path, relative_file, source, macro_index, enabled_targets, mutators)

    # M73: pattern-shape mutators (opt-in `:pattern_shape` target) — pin removal
    # on `^x` nodes. Fallback-routed.
    {pattern_shape_fallback, pattern_shape_skips} =
      pattern_shape_results(ast, relative_file, source, enabled_targets, mutators)

    # M77: conditional mutators (opt-in `:conditional` target) — negate / force
    # if/unless conditions. Fallback-routed (whole-node span replace).
    {conditional_fallback, conditional_skips} =
      conditional_results(ast, relative_file, source, enabled_targets, mutators, macro_index)

    # M81: statement-delete mutators (opt-in `:statement_delete` target) — delete
    # one non-last statement in a function body. Fallback-routed (whole-def
    # span replace; mutator re-emits the def with the statement removed).
    {stmt_delete_fallback, stmt_delete_skips} =
      statement_delete_results(ast, relative_file, source, enabled_targets, mutators)

    # M87: clause-delete mutators (opt-in `:clause_delete` target) — case/cond
    # /with(`else`) clause removal. Fallback-routed (whole-construct span).
    {clause_delete_fallback, clause_delete_skips} =
      clause_delete_results(ast, relative_file, source, enabled_targets, mutators)

    # M94: pipeline-stage-drop mutators (opt-in `:pipeline_drop`). Drop a
    # middle stage from a `|>` chain. Fallback-routed (whole-pipeline span).
    {pipeline_fallback, pipeline_skips} =
      pipeline_drop_results(ast, relative_file, source, enabled_targets, mutators)

    # M94: map-update-drop mutators (opt-in `:map_update_drop`). Drop
    # `%{m | k: v}` → `m`. Fallback-routed (whole-`%{}` literal span).
    {map_update_fallback, map_update_skips} =
      map_update_drop_results(ast, relative_file, source, enabled_targets, mutators)

    # M94: receive-timeout mutators (opt-in `:receive_timeout`). Mutate
    # the `after` timeout (0 / :infinity / drop). Fallback-routed.
    {receive_timeout_fallback, receive_timeout_skips} =
      receive_timeout_results(ast, relative_file, source, enabled_targets, mutators)

    plan = %Plan{
      schema: dispatch_schema ++ literal_schema,
      fallback:
        attribute_fallback ++
          guard_fallback ++
          env_fallback ++
          pattern_fallback ++
          variable_fallback ++
          pattern_shape_fallback ++
          conditional_fallback ++
          stmt_delete_fallback ++
          clause_delete_fallback ++
          pipeline_fallback ++ map_update_fallback ++ receive_timeout_fallback,
      invalid: [],
      skipped:
        diagnostic_skips(diagnostics, oracle) ++
          dispatch_skips ++
          literal_skips ++
          attribute_skips ++
          guard_skips ++
          env_skips ++
          pattern_skips ++
          variable_skips ++
          pattern_shape_skips ++
          conditional_skips ++
          stmt_delete_skips ++
          clause_delete_skips ++
          pipeline_skips ++
          map_update_skips ++
          receive_timeout_skips,
      matched_pairs: matched
    }

    # M100: `@mutalisk_ignore true` excludes every mutant in the marked module.
    apply_module_ignores(plan, Mut.AstWalk.ignored_modules(ast))
  end

  # Drop mutants whose enclosing module is `@mutalisk_ignore true`, recording
  # them as skipped (reason `:mutalisk_ignore`) so the metric is visible rather
  # than a silent disappearance. No ignored modules -> plan unchanged.
  defp apply_module_ignores(plan, ignored) do
    if MapSet.size(ignored) == 0 do
      plan
    else
      {kept_schema, dropped_schema} =
        Enum.split_with(plan.schema, &(not MapSet.member?(ignored, &1.module)))

      {kept_fallback, dropped_fallback} =
        Enum.split_with(plan.fallback, &(not MapSet.member?(ignored, &1.module)))

      ignore_skips = Enum.map(dropped_schema ++ dropped_fallback, &mutant_ignore_skip/1)

      %{
        plan
        | schema: kept_schema,
          fallback: kept_fallback,
          skipped: plan.skipped ++ ignore_skips
      }
    end
  end

  defp mutant_ignore_skip(%Mutant{} = mutant) do
    %{
      file: mutant.file,
      line: mutant.line,
      column: mutant.column,
      syntactic_name: mutant.mutation_kind,
      reason: :mutalisk_ignore,
      detail: nil
    }
  end

  # M77: conditional candidates via a syntactic AST walk. When the target is
  # off, no walk happens.
  #
  # Tier-3 trust cross-check (ENV_WALKER.md): the syntactic walk finds every
  # `if`/`unless`-shaped node, but a shadowed special form (`import Kernel,
  # except: [if: 2]` + a custom `if` macro) would be mutated as if it were the
  # Kernel form. So — exactly as the env-walker path does — gate each candidate
  # on tracer proof that it resolved to `Kernel.if/2`/`Kernel.unless/2`
  # (`kernel_control_flow_proven?/3`). Unproven sites are SKIPPED, not mutated.
  # This is a pure post-filter: it can only remove candidates, so surviving
  # candidates keep their stable IDs (no migration). On a normal project every
  # `if`/`unless` is the Kernel form and proves out, so nothing changes.
  defp conditional_results(ast, relative_file, source, enabled_targets, mutators, macro_index) do
    if :conditional in enabled_targets do
      {proven, opaque} =
        ast
        |> Mut.AstWalk.conditional_candidates(file: relative_file, source: source)
        |> Enum.split_with(fn candidate ->
          Mut.OpaquePolicy.kernel_control_flow_proven?(
            candidate.node,
            macro_index,
            candidate.file
          )
        end)

      {mutants, skips} = enabled_fallback_results(proven, :conditional, nil, mutators, source)
      {mutants, skips ++ Enum.map(opaque, &skip(&1, :opaque_control_flow, nil))}
    else
      {[], []}
    end
  end

  # M81: statement-delete candidates. Off-target -> no walk.
  defp statement_delete_results(ast, relative_file, source, enabled_targets, mutators) do
    if :statement_delete in enabled_targets do
      candidates =
        Mut.AstWalk.statement_delete_candidates(ast, file: relative_file, source: source)

      enabled_fallback_results(candidates, :statement_delete, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M87: clause-delete candidates. Off-target -> no walk.
  defp clause_delete_results(ast, relative_file, source, enabled_targets, mutators) do
    if :clause_delete in enabled_targets do
      candidates =
        Mut.AstWalk.clause_delete_candidates(ast, file: relative_file, source: source)

      enabled_fallback_results(candidates, :clause_delete, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M94: pipeline-stage-drop candidates. Off-target -> no walk.
  defp pipeline_drop_results(ast, relative_file, source, enabled_targets, mutators) do
    if :pipeline_drop in enabled_targets do
      candidates =
        Mut.AstWalk.pipeline_drop_candidates(ast, file: relative_file, source: source)

      enabled_fallback_results(candidates, :pipeline_drop, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M94: map-update-drop candidates. Off-target -> no walk.
  defp map_update_drop_results(ast, relative_file, source, enabled_targets, mutators) do
    if :map_update_drop in enabled_targets do
      candidates =
        Mut.AstWalk.map_update_drop_candidates(ast, file: relative_file, source: source)

      enabled_fallback_results(candidates, :map_update_drop, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M94: receive-timeout candidates. Off-target -> no walk.
  defp receive_timeout_results(ast, relative_file, source, enabled_targets, mutators) do
    if :receive_timeout in enabled_targets do
      candidates =
        Mut.AstWalk.receive_timeout_candidates(ast, file: relative_file, source: source)

      enabled_fallback_results(candidates, :receive_timeout, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M73: pin candidates discovered by a syntactic AST walk (the `^` operator
  # only appears in patterns). When the target is off, no walk happens.
  defp pattern_shape_results(ast, relative_file, source, enabled_targets, mutators) do
    if :pattern_shape in enabled_targets do
      candidates = Mut.AstWalk.pin_candidates(ast, file: relative_file, source: source)
      enabled_fallback_results(candidates, :pattern_shape, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M52: apply the active scalar-literal mutators to schema-literal
  # candidates, producing :schema mutants (placed by Mut.SchemaPlacer via
  # ast_path_hash). CollectionEmpty stays fallback; it is filtered out
  # because its `applicable?/2` requires `engine == :fallback`.
  defp schema_literal_results(candidates, enabled_targets, mutators, source) do
    # Preserve enablement: integer/boolean require :body_literal, the
    # env-walker literals require :env_walker. Engine moved to schema; the
    # target gate is unchanged from the fallback era.
    literal_mutators =
      Enum.filter(mutators, fn mutator ->
        (target?(mutator, :body_literal) and :body_literal in enabled_targets) or
          (target?(mutator, :env_walker) and :env_walker in enabled_targets)
      end)

    if literal_mutators == [] do
      {[], []}
    else
      candidates
      |> Enum.map(&schema_literal_mutants(&1, literal_mutators, source))
      |> Enum.reduce({[], []}, fn
        {:mutants, mutants}, {all, skips} -> {all ++ mutants, skips}
        {:skip, skip}, {all, skips} -> {all, skips ++ [skip]}
      end)
    end
  end

  defp schema_literal_mutants(%AstCandidate{} = candidate, literal_mutators, source) do
    ctx = literal_schema_context(candidate)

    literal_mutators
    |> Enum.flat_map(&mutations(candidate, nil, &1, ctx, :schema, source))
    |> case do
      [] -> {:skip, skip(candidate, :no_applicable_mutator, nil)}
      mutants -> {:mutants, mutants}
    end
  end

  defp literal_schema_context(candidate) do
    %Context{
      oracle_site: nil,
      enclosing_function: nil,
      enclosing_module: candidate.enclosing_module,
      file: candidate.file,
      source_span: candidate.source_span,
      ast_path: candidate.ast_path,
      ast_path_hash: candidate.ast_path_hash,
      env_context: nil,
      engine: :schema
    }
  end

  @collection_literal_names ~w(__list_literal__ __tuple_literal__ __map_literal__ __ntuple_literal__)a

  defp env_walker_candidates(_path, relative_file, source, macro_index) do
    case Mut.EnvWalker.parse_string(source, relative_file) do
      {:ok, encoded_ast} ->
        encoded_ast
        |> Mut.EnvWalker.collect_literal_candidates(
          file: relative_file,
          source: source,
          macro_index: macro_index
        )
        # M52: body-position scalars route through the schema path; keep
        # collection candidates here (CollectionEmpty, fallback-routed).
        # M53: pattern-position scalars (`env_context == :match`) cannot be
        # schema-placed, so they also stay on the env-walker fallback path.
        |> Enum.filter(fn {candidate, _snap} ->
          candidate.syntactic_name in @collection_literal_names or
            candidate.env_context == :match
        end)

      _ ->
        []
    end
  end

  # M40 commit 5 (strings) + M44 (float / nil): env-walker fallback
  # results. Candidates from `Mut.EnvWalker.collect_literal_candidates/2`
  # are routed through the standard fallback mutant pipeline when the
  # `:env_walker` target is enabled. The candidate stream is already
  # filtered to body-literal-eligible snapshots; each mutator's own
  # `applicable?/2` enforces engine and shape constraints, so a literal
  # whose mutator is disabled becomes a skip, not a mutant.
  defp env_walker_results([], _enabled_targets, _mutators, _source), do: {[], []}

  defp env_walker_results(pairs, enabled_targets, mutators, source) do
    if :env_walker in enabled_targets do
      candidates = Enum.map(pairs, fn {candidate, _snap} -> candidate end)
      enabled_fallback_results(candidates, :env_walker, nil, mutators, source)
    else
      {[], []}
    end
  end

  # M53: pattern-position scalar literals (`env_context == :match`), gated by
  # the opt-in `:pattern_literal` target. Fallback-routed (pattern schemata
  # are not expression-position safe); the literal mutators that carry the
  # `:pattern_literal` target and admit `env_context == :match` mutate them.
  defp pattern_literal_results([], _enabled_targets, _mutators, _source), do: {[], []}

  defp pattern_literal_results(pairs, enabled_targets, mutators, source) do
    candidates = Enum.map(pairs, fn {candidate, _snap} -> candidate end)

    case pattern_literal_mutators(enabled_targets, mutators) do
      [] ->
        {[], Enum.map(candidates, &skip(&1, :pattern_literal_engine_disabled, nil))}

      active ->
        enabled_fallback_results(candidates, :pattern_literal, nil, active, source)
    end
  end

  # M63: with `--enable pattern_literal`, the FULL pattern-literal surface fires.
  # By default, only the graduated subset (IntegerLiteral-in-pattern) fires —
  # the one surface that cleared the M62 sharpened gate.
  defp graduated_pattern_active?(mutators) do
    Enum.any?(mutators, &(&1 in Defaults.graduated_pattern_literal_mutators()))
  end

  defp pattern_literal_mutators(enabled_targets, mutators) do
    if :pattern_literal in enabled_targets do
      Enum.filter(mutators, &target?(&1, :pattern_literal))
    else
      Enum.filter(mutators, &(&1 in Defaults.graduated_pattern_literal_mutators()))
    end
  end

  # M54: variable-reference candidates from a binding-scope-aware walk, gated
  # by the opt-in `:variable` target. When the target is off, no walk happens
  # (zero overhead, zero churn for existing plans).
  defp variable_results(path, relative_file, source, macro_index, enabled_targets, mutators) do
    if :variable in enabled_targets do
      candidates = variable_candidates(path, relative_file, source, macro_index)
      enabled_fallback_results(candidates, :variable, nil, mutators, source)
    else
      {[], []}
    end
  end

  defp variable_candidates(_path, relative_file, source, macro_index) do
    case Mut.EnvWalker.parse_string(source, relative_file) do
      {:ok, encoded_ast} ->
        encoded_ast
        |> Mut.EnvWalker.collect_variable_candidates(
          file: relative_file,
          source: source,
          macro_index: macro_index
        )
        |> Enum.map(fn {candidate, _snap} -> candidate end)

      _ ->
        []
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
      # M90: `:guard_boolean` is an opt-in companion target to `:guard` — it
      # shares the guard walk + env_context but is gated separately so
      # adding `GuardBoolean` to `@opt_in` doesn't fire on the default
      # plan (`:guard` is in `@default_enabled_targets`, `:guard_boolean`
      # is not). When enabled, its mutators join `guard_mutators`.
      extra =
        if :guard_boolean in enabled_targets,
          do: Enum.filter(mutators, &target?(&1, :guard_boolean)),
          else: []

      guard_mutators = Enum.filter(mutators, &target?(&1, :guard)) ++ extra
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
      engine: :fallback,
      bound_vars: candidate.bound_vars,
      type_hint: candidate.type_hint,
      other_uses?: candidate.other_uses?
    }
  end

  # The env-context a fallback mutant carries, by target. Three cases:
  #   * `:guard` — the guard's env_context (from the site, else the candidate).
  #   * pattern targets (`:pattern_literal` M53, `:pattern_shape` M73) — the
  #     candidate's `:match` context, which the literal/Pin mutators require.
  #   * every other target — plain expression position (`nil`): module
  #     attributes, env-walker collections, variable reads, and the whole-node
  #     structural mutators (conditional/statement_delete/clause_delete/
  #     pipeline_drop/map_update_drop/receive_timeout) need no env context.
  # `nil` is the correct default, so unlisted targets fall through to it.
  @pattern_targets [:pattern_literal, :pattern_shape]

  defp fallback_env_context(candidate, site, :guard),
    do: (site && site.env_context) || candidate.env_context

  defp fallback_env_context(candidate, _site, target) when target in @pattern_targets,
    do: candidate.env_context

  defp fallback_env_context(_candidate, _site, _target), do: nil

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
