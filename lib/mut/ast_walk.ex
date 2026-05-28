defmodule Mut.AstWalk do
  @moduledoc "Walks source ASTs for oracle candidates."

  alias Mut.Oracle.AstCandidate
  alias Mut.SourceSpan.Compute

  @binary_ops ~w(+ - * / < <= > >= == != === !== and or && ||)a
  @unary_ops ~w(not !)a

  @special_forms ~w(
    case cond if unless try with for receive fn __MODULE__ __ENV__ __CALLER__ __DIR__
    __STACKTRACE__ = -> | alias require import use defmodule def defp defmacro defmacrop
    defguard defguardp defstruct defprotocol defimpl defdelegate @ &
  )a

  @no_descend ~w(& quote unquote unquote_splicing)a
  @function_defs ~w(def defp defmacro defmacrop defguard defguardp)a
  @reserved_attributes ~w(
    moduledoc doc typedoc behaviour impl spec type typep opaque callback macrocallback
    optional_callbacks before_compile after_compile after_verify on_definition on_load dialyzer
    external_resource vsn nifs derive enforce_keys fallback_to_any
  )a

  @type path_elem :: {:elem, atom(), non_neg_integer()}

  @spec dispatch_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def dispatch_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source)
    line_offsets = if source, do: Compute.line_offsets(source), else: %{}
    acc = acc(file, source, line_offsets, false)

    {_ast, acc} = Macro.traverse(ast, acc, &pre/2, &post/2)

    acc.candidates
    |> Enum.reverse()
    |> Enum.sort_by(&span_start_byte/1)
  end

  @spec attribute_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def attribute_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)
    acc = acc(file, source, line_offsets, false)

    {_ast, acc} = Macro.traverse(ast, acc, &attribute_pre/2, &post/2)

    acc.candidates
    |> Enum.reverse()
    |> Enum.sort_by(&span_start_byte/1)
  end

  @doc """
  M73: pin candidates — `^var` pin operators in patterns. The pattern-shape
  surface (the `_` ↔ named-var directions are non-viable by construction —
  see `Mut.Mutator.Pin`). Each candidate carries the span of the whole `^var`
  (so `Mut.Mutator.Pin` can replace it with the inner `var`, i.e. unpin).
  Requires `:source`.
  """
  @spec pin_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def pin_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)
    acc = acc(file, source, line_offsets, false) |> Map.put(:skip_pins, MapSet.new())

    {_ast, acc} = Macro.traverse(ast, acc, &pin_pre/2, &post/2)

    acc.candidates
    |> Enum.reverse()
    |> Enum.sort_by(&span_start_byte/1)
  end

  @doc """
  M77: `if`/`unless` candidates for conditional mutation (negate / force).
  Block form only (`do … end`, which carries `:end` metadata so the whole node
  can be span-replaced); the candidate's node is the full `if`/`unless` so
  `Mut.Mutator.NegateConditional` can re-emit it with the condition mutated.
  `quote`/codegen subtrees are pruned (not mutated). Requires `:source`.
  """
  @spec conditional_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def conditional_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)
    acc = acc(file, source, line_offsets, false)

    {_ast, acc} = Macro.traverse(ast, acc, &conditional_pre/2, &post/2)

    acc.candidates
    |> Enum.reverse()
    |> Enum.sort_by(&span_start_byte/1)
  end

  defp conditional_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = maybe_conditional_candidate(node, path, acc)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp maybe_conditional_candidate({name, meta, [_cond, kw]} = node, path, acc)
       when name in [:if, :unless] and is_list(kw) do
    with true <- Keyword.keyword?(kw) and Keyword.has_key?(kw, :do),
         span when not is_nil(span) <- block_node_span(meta, acc) do
      candidate = %AstCandidate{
        file: acc.file,
        line: Keyword.get(meta, :line),
        column: Keyword.get(meta, :column),
        syntactic_name: name,
        syntactic_arity: 2,
        source_span: span,
        env_context: nil,
        enclosing_module: current_module(acc),
        ast_path: path,
        ast_path_hash: path_hash(path),
        node: node
      }

      %{acc | candidates: [candidate | acc.candidates]}
    else
      _ -> acc
    end
  end

  defp maybe_conditional_candidate(_node, _path, acc), do: acc

  # Span of a do/end block node, from its `:line`/`:column` to just past the
  # `end` keyword (`:end` metadata). nil for keyword-form `if c, do: v` (no
  # `:end`), which is skipped.
  defp block_node_span(meta, acc) do
    with start_line when is_integer(start_line) <- Keyword.get(meta, :line),
         start_col when is_integer(start_col) <- Keyword.get(meta, :column),
         end_kw when is_list(end_kw) <- Keyword.get(meta, :end),
         end_line when is_integer(end_line) <- Keyword.get(end_kw, :line),
         end_col when is_integer(end_col) <- Keyword.get(end_kw, :column) do
      end_column = end_col + 3

      %Mut.SourceSpan{
        file: acc.file,
        start_line: start_line,
        start_column: start_col,
        end_line: end_line,
        end_column: end_column,
        start_byte: byte_offset(acc.source, acc.line_offsets, start_line, start_col),
        end_byte: byte_offset(acc.source, acc.line_offsets, end_line, end_column)
      }
    else
      _ -> nil
    end
  end

  @doc """
  M81: statement-delete candidates. Finds top-level `def`/`defp` whose body is a
  multi-statement `__block__`, and emits one candidate per non-last statement
  that passes the orphan-binding hazard (a deleted statement that binds a name
  later statements read would yield an undefined-variable compile error).
  Candidate's source_span is the def's whole-node span (via `:end` meta); the
  mutation re-renders the def with the statement removed. Body-position only:
  the walk visits the file's `defmodule` -> def/defp nodes directly, so
  pattern/guard contexts and `case`/`with` scrutinee blocks are never reached.
  Requires `:source`.
  """
  @spec statement_delete_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def statement_delete_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    acc = %{
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: []
    }

    {_ast, acc} = Macro.prewalk(ast, acc, &sd_visit/2)
    acc.candidates |> Enum.reverse() |> Enum.sort_by(&span_start_byte/1)
  end

  defp sd_visit({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    {node, %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}}
  end

  defp sd_visit({name, meta, [_head, body_kw]} = node, acc) when name in [:def, :defp] do
    with true <- Keyword.keyword?(body_kw),
         {:__block__, _bm, stmts} <- Keyword.get(body_kw, :do),
         true <- length(stmts) >= 2,
         span when not is_nil(span) <- block_node_span(meta, acc) do
      {node, emit_statement_delete_candidates(node, stmts, span, acc)}
    else
      _ -> {node, acc}
    end
  end

  defp sd_visit(node, acc), do: {node, acc}

  defp emit_statement_delete_candidates(def_node, stmts, span, acc) do
    indexed = Enum.with_index(stmts)
    # Exclude the LAST statement (its value is the def's return; deletion is the
    # noisiest sub-class per M39/M81 — opt-in within opt-in, excluded here).
    non_last = Enum.drop(indexed, -1)

    Enum.reduce(non_last, acc, fn {stmt, i}, acc ->
      before = Enum.take(stmts, i)
      later = Enum.drop(stmts, i + 1)

      cond do
        orphan_binding_hazard?(stmt, later) ->
          acc

        unused_binding_hazard?(stmt, before, later) ->
          acc

        true ->
          cand = build_sd_candidate(def_node, i, span, acc)
          %{acc | candidates: [cand | acc.candidates]}
      end
    end)
  end

  defp build_sd_candidate(def_node, stmt_index, span, acc) do
    # Synthesized ast_path ending in the statement index, so the mutator can
    # recover it via ctx.ast_path; the hash makes the stable id unique per
    # {def, index}, even though candidates share the def's span.
    {_def_name, def_meta, _args} = def_node
    line = Keyword.get(def_meta, :line)
    col = Keyword.get(def_meta, :column)
    ast_path = [:statement_delete, acc.file, line, col, stmt_index]

    %AstCandidate{
      file: acc.file,
      line: line,
      column: col,
      syntactic_name: :statement_delete,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: List.first(acc.module_stack),
      ast_path: ast_path,
      ast_path_hash: path_hash(ast_path),
      node: def_node
    }
  end

  # Orphan-binding hazard: any name bound by an `=` LHS in `stmt` that is
  # read by any `later` statement -> deleting `stmt` makes it undefined.
  # Bindings via `with`/`for` `<-`, function-head args, etc. are not the
  # block-statement case (those clauses introduce bindings into THEIR own
  # do-blocks, not into the enclosing function body).
  defp orphan_binding_hazard?(stmt, later) when is_list(later) do
    bound = collect_lhs_bindings(stmt)

    if bound == [] do
      false
    else
      reads = collect_var_reads(later)
      Enum.any?(bound, &(&1 in reads))
    end
  end

  defp collect_lhs_bindings(stmt) do
    {_ast, names} =
      Macro.prewalk(stmt, [], fn
        {:=, _, [lhs, _rhs]} = node, acc -> {node, pattern_vars(lhs) ++ acc}
        node, acc -> {node, acc}
      end)

    Enum.uniq(names)
  end

  defp pattern_vars(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, [], fn
        # `^x` pinned vars are READS, not new bindings — replace with a leaf
        # sentinel so prewalk doesn't descend into the inner var.
        {:^, _meta, _args}, acc ->
          {{:__pinned__, [], []}, acc}

        {name, _meta, ctx} = node, acc
        when is_atom(name) and is_atom(ctx) and name != :_ ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  defp collect_var_reads(asts) when is_list(asts) do
    {_ast, names} =
      Macro.prewalk(asts, [], fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  # M89 unused-binding hazard: deleting `stmt` would leave one of the
  # preceding `=`-bound names with no readers — Elixir emits an
  # "unused variable" warning, which under `--warnings-as-errors` (the
  # default `bin/verify` lint posture plus most prod compile flags) is
  # a compile error, surfacing as the Invalid class on plug_crypto.
  # The analog of the orphan-binding hazard, in the other direction:
  # orphan = "stmt binds X, later reads it"; unused = "earlier bound X,
  # stmt reads it, no other reader".
  #
  # Conservative shape: gather all `=`-LHS-bound names from `before` (the
  # existing collect_lhs_bindings already walks a list-of-stmts via
  # Macro.prewalk); gather reads from `stmt` and `later`. If any binding's
  # only reader is in `stmt` (the candidate for deletion), gate.
  defp unused_binding_hazard?(stmt, before, later) do
    bound = collect_lhs_bindings(before)

    if bound == [] do
      false
    else
      stmt_reads = collect_var_reads([stmt])
      later_reads = collect_var_reads(later)
      Enum.any?(bound, fn name -> name in stmt_reads and name not in later_reads end)
    end
  end

  @doc """
  M87: clause-delete candidates for `case`/`cond`/`with`. Emits one candidate per
  deletable clause; the candidate's node is the whole construct (block-form,
  spanned via `:end`), and the mutation re-emits it with that clause removed.

  Hazards (skipped in the collector, not at mutate time):
    * `case` / `cond`: the **last** clause is the catch-all — deleting it can
      crash on no-match. Excluded.
    * `cond`: any `true ->` clause is the explicit fallback; deletion crashes
      on no-match. Excluded.
    * `with`: only the `else` clauses are mutated (deleting one of ≥ 2). The
      `<-` chain is skipped — deleting a binding step is orphan-binding-shaped
      noise (M81-territory) plus structurally invalid when the binding is read
      in `do`. Single-else-clause withs are excluded (would remove the only
      `else`).
    * M89: clauses whose body is a single `raise`/`throw`/`exit` call (or a
      block whose last statement is one) are skipped — the idiomatic
      "shouldn't-happen" arms drive the dominant equivalent class on plug.
    * M90 `receive`: the `:do` clauses are mutated; **last** clause and
      single-clause receives skipped (same conservative discipline as case).
      The `after:` timeout clause is not touched (single-statement, not a
      clause list).
    * M90 `try`: the `:rescue`, `:catch`, and `:else` sections are each
      mutated independently; per-section last-clause and single-clause
      exclusion. `:after` is a single body, not touched.
  """
  @spec clause_delete_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def clause_delete_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    acc = %{
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: []
    }

    {_ast, acc} = Macro.prewalk(ast, acc, &cd_visit/2)
    acc.candidates |> Enum.reverse() |> Enum.sort_by(&span_start_byte/1)
  end

  defp cd_visit({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    {node, %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}}
  end

  defp cd_visit({:case, meta, [_scrutinee, [{:do, clauses}]]} = node, acc)
       when is_list(clauses) do
    {node, emit_clause_candidates(node, clauses, :case, meta, acc)}
  end

  defp cd_visit({:cond, meta, [[{:do, clauses}]]} = node, acc) when is_list(clauses) do
    {node, emit_clause_candidates(node, clauses, :cond, meta, acc)}
  end

  defp cd_visit({:with, meta, args} = node, acc) when is_list(args) do
    {node, emit_with_else_candidates(node, args, meta, acc)}
  end

  # M90 receive: same shape as cond ({:receive, meta, [[do: clauses, ...]]}).
  defp cd_visit({:receive, meta, [args]} = node, acc) when is_list(args) do
    case Keyword.get(args, :do) do
      clauses when is_list(clauses) ->
        {node, emit_clause_candidates(node, clauses, :receive, meta, acc)}

      _ ->
        {node, acc}
    end
  end

  # M90 try: {:try, meta, [[do: body, rescue: clauses, catch: clauses, ...]]}.
  defp cd_visit({:try, meta, [args]} = node, acc) when is_list(args) do
    {node,
     acc
     |> emit_try_section(node, args, :rescue, meta)
     |> emit_try_section(node, args, :catch, meta)
     |> emit_try_section(node, args, :else, meta)}
  end

  defp cd_visit(node, acc), do: {node, acc}

  defp emit_clause_candidates(node, clauses, kind, meta, acc) do
    with span when not is_nil(span) <- block_node_span(meta, acc),
         indexed = Enum.with_index(clauses),
         non_last = Enum.drop(indexed, -1),
         deletable = filter_deletable(non_last, kind),
         deletable = Enum.reject(deletable, fn {clause, _i} -> error_only_clause?(clause) end),
         true <- deletable != [] do
      Enum.reduce(deletable, acc, fn {_clause, i}, acc ->
        cand = build_clause_candidate(node, i, span, section_for(kind), acc)
        %{acc | candidates: [cand | acc.candidates]}
      end)
    else
      _ -> acc
    end
  end

  defp emit_with_else_candidates(node, args, meta, acc) do
    with span when not is_nil(span) <- block_node_span(meta, acc),
         last when is_list(last) <- List.last(args),
         true <- Keyword.keyword?(last),
         else_clauses when is_list(else_clauses) <- Keyword.get(last, :else),
         true <- length(else_clauses) >= 2 do
      indexed = Enum.with_index(else_clauses)
      deletable = Enum.reject(indexed, fn {clause, _i} -> error_only_clause?(clause) end)

      Enum.reduce(deletable, acc, fn {_clause, i}, acc ->
        cand = build_clause_candidate(node, i, span, :with_else, acc)
        %{acc | candidates: [cand | acc.candidates]}
      end)
    else
      _ -> acc
    end
  end

  defp filter_deletable(indexed, :cond),
    do: Enum.reject(indexed, fn {clause, _i} -> cond_true_clause?(clause) end)

  defp filter_deletable(indexed, _kind), do: indexed

  defp cond_true_clause?({:->, _meta, [[cond_expr], _body]}), do: cond_expr == true
  defp cond_true_clause?(_node), do: false

  # M90 try-section emitter. Each section's clauses are filtered independently:
  # need ≥2 clauses (so deletion of non-last is meaningful and the section
  # remains structurally valid); last clause excluded (catch-all preserved);
  # error-only clauses skipped (M89 equiv-reduction hazard).
  defp emit_try_section(acc, node, args, section, meta) do
    with clauses when is_list(clauses) <- Keyword.get(args, section),
         true <- length(clauses) >= 2,
         span when not is_nil(span) <- block_node_span(meta, acc) do
      indexed = Enum.with_index(clauses)
      non_last = Enum.drop(indexed, -1)
      deletable = Enum.reject(non_last, fn {clause, _i} -> error_only_clause?(clause) end)

      Enum.reduce(deletable, acc, fn {_clause, i}, acc ->
        cand = build_clause_candidate(node, i, span, try_section_tag(section), acc)
        %{acc | candidates: [cand | acc.candidates]}
      end)
    else
      _ -> acc
    end
  end

  defp try_section_tag(:rescue), do: :try_rescue
  defp try_section_tag(:catch), do: :try_catch
  defp try_section_tag(:else), do: :try_else

  @doc """
  M94: pipeline-drop candidates. Finds the **top** of each `|>` chain (a
  `|>` node whose enclosing position is not another `|>`), flattens the
  chain into `[input, stage1, ..., stageN]`, and emits one candidate per
  middle stage (0-indexed positions `2..N-2` inclusive in the flat list).
  Skips chains shorter than 4 elements (need ≥3 stages so at least one
  middle exists). The first stage (index 1) is skipped — dropping it
  feeds the raw input to the next stage, semantically "destroying" the
  input. The last stage (index N-1, where N = `length(stages)`) is
  skipped — dropping it makes the upstream chain's result the return,
  often refactoring-equivalent under the test suite.

  Span is custom — pipelines don't have an `:end` keyword token. The
  collector computes start = leftmost leaf's `:line`/`:column`,
  end = rightmost call's `:closing` (or fallback `:end_line`/`:end_column`).
  Skip candidate if either position is unrecoverable.

  Requires `:source`.
  """
  @spec pipeline_drop_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def pipeline_drop_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    acc = %{
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: []
    }

    # Use Macro.traverse with a pre-fn that processes pipeline tops and prunes
    # nested pipes (so the same chain isn't enumerated multiple times).
    {_ast, acc} = Macro.traverse(ast, acc, &pipe_pre/2, &pipe_post/2)
    acc.candidates |> Enum.reverse() |> Enum.sort_by(&span_start_byte/1)
  end

  defp pipe_pre({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    {node, %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}}
  end

  defp pipe_pre({:|>, _meta, _args} = node, acc) do
    # This is the TOP of a pipeline chain (we prune the LHS so sub-pipes
    # never reach this clause). Process and replace with a leaf so the
    # post-walk + sub-tree traversal doesn't re-process.
    acc = emit_pipeline_candidates(node, acc)
    {:__pipeline_pruned__, acc}
  end

  defp pipe_pre(node, acc), do: {node, acc}

  defp pipe_post({:defmodule, _meta, _args} = node, acc) do
    {node, %{acc | module_stack: tl(acc.module_stack)}}
  end

  defp pipe_post(node, acc), do: {node, acc}

  defp emit_pipeline_candidates(top_node, acc) do
    stages = flatten_pipeline(top_node)
    n = length(stages)

    with true <- n >= 4,
         span when not is_nil(span) <- pipeline_span(top_node, acc) do
      # Middle stages: 0-indexed positions 2..n-2 (skip input=0, first stage=1,
      # last stage=n-1).
      indexes = Enum.to_list(2..(n - 2))

      Enum.reduce(indexes, acc, fn i, acc ->
        cand = build_pipeline_candidate(top_node, i, span, acc)
        %{acc | candidates: [cand | acc.candidates]}
      end)
    else
      _ -> acc
    end
  end

  defp build_pipeline_candidate(top_node, stage_index, span, acc) do
    {:|>, meta, _} = top_node
    line = Keyword.get(meta, :line)
    col = Keyword.get(meta, :column)
    ast_path = [:pipeline_drop_stage, acc.file, line, col, stage_index]

    %AstCandidate{
      file: acc.file,
      line: span.start_line,
      column: span.start_column,
      syntactic_name: :pipeline_drop_stage,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: List.first(acc.module_stack),
      ast_path: ast_path,
      ast_path_hash: path_hash(ast_path),
      node: top_node
    }
  end

  defp flatten_pipeline({:|>, _meta, [lhs, rhs]}), do: flatten_pipeline(lhs) ++ [rhs]
  defp flatten_pipeline(other), do: [other]

  # Span of a whole pipeline expression. start = leftmost leaf's
  # `:line`/`:column`; end = rightmost call's `:closing` (or fallback
  # `:end_line`/`:end_column`). nil if either is unrecoverable.
  defp pipeline_span(top_node, acc) do
    with {start_line, start_col} <- leftmost_position(top_node),
         {end_line, end_col} <- rightmost_end_position(top_node) do
      %Mut.SourceSpan{
        file: acc.file,
        start_line: start_line,
        start_column: start_col,
        end_line: end_line,
        end_column: end_col,
        start_byte: byte_offset(acc.source, acc.line_offsets, start_line, start_col),
        end_byte: byte_offset(acc.source, acc.line_offsets, end_line, end_col)
      }
    else
      _ -> nil
    end
  end

  defp leftmost_position({:|>, _meta, [lhs, _rhs]}), do: leftmost_position(lhs)

  defp leftmost_position({_form, meta, _args}) do
    with l when is_integer(l) <- Keyword.get(meta, :line),
         c when is_integer(c) <- Keyword.get(meta, :column) do
      {l, c}
    else
      _ -> nil
    end
  end

  defp leftmost_position(_), do: nil

  defp rightmost_end_position({:|>, _meta, [_lhs, rhs]}), do: rightmost_end_position(rhs)

  defp rightmost_end_position({_form, meta, _args}) do
    cond do
      is_integer(meta[:end_line]) ->
        {meta[:end_line], meta[:end_column]}

      is_list(meta[:closing]) ->
        {Keyword.fetch!(meta[:closing], :line), Keyword.fetch!(meta[:closing], :column) + 1}

      true ->
        nil
    end
  end

  defp rightmost_end_position(_), do: nil

  @doc """
  M94: map-update candidates. Finds `%{base | updates}` nodes and emits
  one candidate per occurrence; the candidate's source span is the whole
  `%{...}` literal (its `:closing` meta yields the end). Plain map
  literals `%{a: 1}` without an update pipe are skipped.
  """
  @spec map_update_drop_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def map_update_drop_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    acc = %{
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: []
    }

    {_ast, acc} = Macro.prewalk(ast, acc, &mu_visit/2)
    acc.candidates |> Enum.reverse() |> Enum.sort_by(&span_start_byte/1)
  end

  defp mu_visit({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    {node, %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}}
  end

  defp mu_visit({:%{}, meta, [{:|, _pipe_meta, [_base, updates]}]} = node, acc)
       when is_list(updates) do
    case Compute.from_meta(meta, acc.source, acc.file, acc.line_offsets) do
      nil ->
        {node, acc}

      %Mut.SourceSpan{} = span ->
        cand = build_map_update_candidate(node, meta, span, acc)
        {node, %{acc | candidates: [cand | acc.candidates]}}
    end
  end

  defp mu_visit(node, acc), do: {node, acc}

  defp build_map_update_candidate(node, meta, span, acc) do
    line = Keyword.get(meta, :line)
    col = Keyword.get(meta, :column)
    ast_path = [:map_update_drop, acc.file, line, col]

    %AstCandidate{
      file: acc.file,
      line: line,
      column: col,
      syntactic_name: :map_update_drop,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: List.first(acc.module_stack),
      ast_path: ast_path,
      ast_path_hash: path_hash(ast_path),
      node: node
    }
  end

  @doc """
  M94: receive-timeout candidates. Finds `receive` blocks that have an
  `after` clause and emits one candidate per occurrence; the mutator
  generates three variants per candidate (timeout `0`, `:infinity`, and
  drop-after). Receives without `after` are skipped (nothing to mutate;
  ClauseDelete M87/M90 covers the `:do` message-handler clauses).

  Source span is the whole `receive` block (uses `block_node_span` since
  receive has `:end` meta).
  """
  @spec receive_timeout_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def receive_timeout_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    acc = %{
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: []
    }

    {_ast, acc} = Macro.prewalk(ast, acc, &rt_visit/2)
    acc.candidates |> Enum.reverse() |> Enum.sort_by(&span_start_byte/1)
  end

  defp rt_visit({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    {node, %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}}
  end

  defp rt_visit({:receive, meta, [args]} = node, acc) when is_list(args) do
    with [{:->, _, [[_t], _body]} | _] <- Keyword.get(args, :after, nil),
         span when not is_nil(span) <- block_node_span(meta, acc) do
      cand = build_receive_timeout_candidate(node, meta, span, acc)
      {node, %{acc | candidates: [cand | acc.candidates]}}
    else
      _ -> {node, acc}
    end
  end

  defp rt_visit(node, acc), do: {node, acc}

  defp build_receive_timeout_candidate(node, meta, span, acc) do
    line = Keyword.get(meta, :line)
    col = Keyword.get(meta, :column)
    ast_path = [:receive_timeout, acc.file, line, col]

    %AstCandidate{
      file: acc.file,
      line: line,
      column: col,
      syntactic_name: :receive_timeout,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: List.first(acc.module_stack),
      ast_path: ast_path,
      ast_path_hash: path_hash(ast_path),
      node: node
    }
  end

  # M89 equiv-reduction hazard: a clause whose body is a single `raise`/
  # `throw`/`exit` call (the idiomatic error-path arm — "this shouldn't
  # happen", "fall through to crash"). When the test suite does not
  # exercise this pattern, deletion produces no observable behaviour
  # change — the dominant equivalent class behind plug 26.8% in M88.
  # Skip these. A clause whose body actually computes a value is kept;
  # only the pure-raise form is filtered.
  defp error_only_clause?({:->, _meta, [_patterns, body]}) do
    raises_only?(body)
  end

  defp error_only_clause?(_node), do: false

  defp raises_only?({:__block__, _, stmts}) when is_list(stmts) do
    case List.last(stmts) do
      nil -> false
      last -> raises_only?(last)
    end
  end

  defp raises_only?({name, _meta, _args}) when name in [:raise, :throw, :exit], do: true
  defp raises_only?(_node), do: false

  defp section_for(:case), do: :case_do
  defp section_for(:cond), do: :cond_do
  defp section_for(:receive), do: :receive_do

  defp build_clause_candidate(construct_node, index, span, section, acc) do
    {kind_atom, meta, _args} = construct_node
    line = Keyword.get(meta, :line)
    col = Keyword.get(meta, :column)
    ast_path = [:clause_delete, acc.file, line, col, section, index]

    %AstCandidate{
      file: acc.file,
      line: line,
      column: col,
      syntactic_name: :clause_delete,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: List.first(acc.module_stack),
      ast_path: ast_path,
      ast_path_hash: path_hash(ast_path),
      node: {kind_atom, meta, elem(construct_node, 2)}
    }
  end

  defp pin_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = note_map_key_pins(node, acc)
    acc = maybe_pin_candidate(node, path, acc)
    {node, push_frame(node, path, acc)}
  end

  # M75 hazard rule: a pin used as a map-pattern KEY (`%{^k => v}`) cannot be
  # unpinned — `%{k => v}` is a compile error (map keys in patterns must be
  # literals or pinned). Record those pins (by `^` line/column) so
  # maybe_pin_candidate skips them. Traversal is pre-order, so the enclosing
  # `%{}` is seen before its key pins.
  defp note_map_key_pins({:%{}, _meta, pairs}, acc) when is_list(pairs) do
    locs =
      for {{:^, caret_meta, [{n, _vm, c}]}, _value} <- pairs,
          is_atom(n) and is_atom(c),
          loc = pin_loc(caret_meta),
          loc != nil,
          into: acc.skip_pins,
          do: loc

    %{acc | skip_pins: locs}
  end

  defp note_map_key_pins(_node, acc), do: acc

  defp pin_loc(caret_meta) do
    with l when is_integer(l) <- Keyword.get(caret_meta, :line),
         c when is_integer(c) <- Keyword.get(caret_meta, :column) do
      {l, c}
    else
      _ -> nil
    end
  end

  defp maybe_pin_candidate({:^, caret_meta, [{name, var_meta, ctx}]} = node, path, acc)
       when is_atom(name) and is_atom(ctx) do
    with cl when is_integer(cl) <- Keyword.get(caret_meta, :line),
         cc when is_integer(cc) <- Keyword.get(caret_meta, :column),
         false <- MapSet.member?(acc.skip_pins, {cl, cc}),
         vl when is_integer(vl) <- Keyword.get(var_meta, :line),
         vc when is_integer(vc) <- Keyword.get(var_meta, :column) do
      end_column = vc + String.length(Atom.to_string(name))

      span = %Mut.SourceSpan{
        file: acc.file,
        start_line: cl,
        start_column: cc,
        end_line: vl,
        end_column: end_column,
        start_byte: byte_offset(acc.source, acc.line_offsets, cl, cc),
        end_byte: byte_offset(acc.source, acc.line_offsets, vl, end_column)
      }

      candidate = %AstCandidate{
        file: acc.file,
        line: cl,
        column: cc,
        syntactic_name: :^,
        syntactic_arity: 1,
        source_span: span,
        env_context: :match,
        enclosing_module: current_module(acc),
        ast_path: path,
        ast_path_hash: path_hash(path),
        node: node
      }

      %{acc | candidates: [candidate | acc.candidates]}
    else
      _ -> acc
    end
  end

  defp maybe_pin_candidate(_node, _path, acc), do: acc

  @doc """
  M23: Body-context literal candidates.

  Re-parses the source with `literal_encoder` so integer / boolean
  literals carry parser metadata (line, column, token), then walks
  the encoded AST and emits `AstCandidate{}` for each integer or
  boolean literal that sits in a function-body position.

  A "body position" means: inside a `def` / `defp` body (NOT
  defmacro/defmacrop bodies — those run at compile time), NOT
  inside a `when` guard, NOT inside a pattern (LHS of `=`,
  function-head args, clause-head patterns), NOT inside
  `quote` / `unquote` / `unquote_splicing`, and NOT inside a
  module-attribute value (the existing AttributeLiteral mutator
  handles those).

  Source is required; without it, no spans can be computed for
  the bare literals.
  """
  @spec body_literal_candidates(opts :: keyword) :: [AstCandidate.t()]
  def body_literal_candidates(opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    case parse_with_literal_encoder(source, file) do
      {:ok, ast} ->
        acc = body_literal_acc(file, source, line_offsets)
        {_ast, acc} = Macro.traverse(ast, acc, &body_literal_pre/2, &post/2)

        acc.candidates
        |> Enum.reverse()
        |> Enum.sort_by(&span_start_byte/1)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  M52: schema-routable scalar literal candidates with **plain-AST**
  positional paths.

  Discovers body-context scalar literals (integer / boolean / string /
  float / atom / nil) over a `literal_encoder` parse, but assigns each an
  `ast_path_hash` that equals the bare literal's position in the **plain**
  AST — so `Mut.SchemaPlacer` (which traverses the plain AST and matches
  by `ast_path_hash`) can place case-gates at them, exactly as it does for
  dispatch mutants. This is what lets the literal catalogue bake into one
  instrumented schema build instead of per-mutant fallback recompile.

  Mechanism: parse with a *marked* literal_encoder, then a two-pass
  normalization unwraps the marked blocks that distort the non-literal
  spine — blocks wrapping collections (which add a level) and blocks in
  2-tuple key position (keyword/struct keys, `{:ok, _}` tags — which
  change a parent's `node_kind`). Marked scalar-value blocks remain as
  leaves carrying their span; their path over the normalized AST equals
  the bare literal's path over the plain AST. Verified byte-identical for
  dispatch/guard/attribute across the corpus (no non-literal churn).

  Collections (list / tuple / map) are NOT returned here — they stay on
  the fallback engine (M50). Source is required for spans.
  """
  @spec schema_literal_candidates(opts :: keyword) :: [AstCandidate.t()]
  def schema_literal_candidates(opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.fetch!(opts, :source)
    line_offsets = Compute.line_offsets(source)

    case parse_marked(source, file) do
      {:ok, ast} ->
        normalized = normalize_marked(ast)
        acc = body_literal_acc(file, source, line_offsets)
        {_ast, acc} = Macro.traverse(normalized, acc, &schema_literal_pre/2, &post/2)

        acc.candidates
        |> Enum.reverse()
        |> Enum.sort_by(&span_start_byte/1)

      {:error, _reason} ->
        []
    end
  end

  defp parse_marked(source, file) do
    Code.string_to_quoted(source,
      file: file,
      columns: true,
      token_metadata: true,
      emit_warnings: false,
      literal_encoder: fn lit, meta -> {:ok, {:__block__, [__mut_lit__: true] ++ meta, [lit]}} end
    )
  end

  # Restore the non-literal spine to plain-identical: unwrap marked blocks
  # that wrap collections (extra path level) and marked blocks in 2-tuple
  # key position (change a parent node_kind). Two passes because unwrapping
  # a collection block exposes a 2-tuple whose key must then be unwrapped.
  defp normalize_marked(ast) do
    ast
    |> Macro.prewalk(fn
      {:__block__, meta, [value]} = node ->
        if marked?(meta) and collection_value?(value), do: value, else: node

      node ->
        node
    end)
    |> Macro.prewalk(fn
      {{:__block__, meta, [key]}, value} ->
        if marked?(meta), do: {key, value}, else: {{:__block__, meta, [key]}, value}

      node ->
        node
    end)
  end

  defp marked?(meta), do: is_list(meta) and Keyword.get(meta, :__mut_lit__, false)

  defp collection_value?(value),
    do: is_list(value) or (is_tuple(value) and tuple_size(value) == 2)

  defp schema_literal_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = maybe_schema_literal_candidate(node, path, acc)

    if no_descend?(node) or marked_scalar_block?(node) do
      {prune_marked(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp maybe_schema_literal_candidate({:__block__, meta, [value]} = node, path, acc) do
    cond do
      not marked?(meta) -> acc
      not scalar_literal?(value) -> acc
      not body_position?(path) -> acc
      true -> add_schema_literal(acc, node, value, path, meta)
    end
  end

  defp maybe_schema_literal_candidate(_node, _path, acc), do: acc

  defp scalar_literal?(value) do
    is_integer(value) or is_float(value) or is_binary(value) or is_atom(value)
  end

  defp marked_scalar_block?({:__block__, meta, [value]}),
    do: marked?(meta) and scalar_literal?(value)

  defp marked_scalar_block?(_node), do: false

  defp prune_marked({:__block__, meta, [_value]}), do: {:__block__, meta, []}
  defp prune_marked(node), do: prune(node)

  defp add_schema_literal(acc, node, value, path, meta) do
    case Keyword.fetch(meta, :line) do
      {:ok, line} ->
        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: Keyword.get(meta, :column),
          syntactic_name: schema_literal_name(value),
          syntactic_arity: 0,
          source_span: literal_span(meta, value, acc),
          env_context: nil,
          enclosing_module: current_module(acc),
          ast_path: path,
          ast_path_hash: path_hash(path),
          node: node
        }

        %{acc | candidates: [candidate | acc.candidates]}

      :error ->
        acc
    end
  end

  defp schema_literal_name(value) when is_integer(value), do: :integer_literal
  defp schema_literal_name(value) when is_boolean(value), do: :boolean_literal
  defp schema_literal_name(value) when is_float(value), do: :float_literal
  defp schema_literal_name(value) when is_binary(value), do: :string_literal
  defp schema_literal_name(nil), do: :nil_literal
  defp schema_literal_name(value) when is_atom(value), do: :atom_literal

  @spec guard_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def guard_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source)
    line_offsets = if source, do: Compute.line_offsets(source), else: %{}
    acc = acc(file, source, line_offsets, true)

    {_ast, acc} = Macro.traverse(ast, acc, &guard_pre/2, &post/2)

    acc.candidates
    |> Enum.reverse()
    |> Enum.sort_by(&span_start_byte/1)
  end

  defp parse_with_literal_encoder(source, file) do
    Code.string_to_quoted(source,
      file: file,
      columns: true,
      token_metadata: true,
      emit_warnings: false,
      literal_encoder: fn lit, meta -> {:ok, {:__block__, meta, [lit]}} end
    )
  end

  defp body_literal_acc(file, source, line_offsets) do
    %{
      frames: [],
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: [],
      span_fallback?: false
    }
  end

  defp body_literal_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = maybe_body_literal_candidate(node, path, acc)

    if no_descend?(node) or body_literal_block?(node) do
      {prune_body_literal(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp maybe_body_literal_candidate({:__block__, meta, [value]} = node, path, acc) do
    cond do
      not (is_integer(value) or is_boolean(value)) ->
        acc

      not body_position?(path) ->
        acc

      true ->
        add_body_literal(acc, node, value, path, meta)
    end
  end

  defp maybe_body_literal_candidate(_node, _path, acc), do: acc

  defp add_body_literal(acc, node, value, path, meta) do
    case Keyword.fetch(meta, :line) do
      {:ok, line} ->
        column = Keyword.get(meta, :column)
        span = literal_span(meta, value, acc)

        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: column,
          syntactic_name: literal_syntactic_name(value),
          syntactic_arity: 0,
          source_span: span,
          env_context: nil,
          enclosing_module: current_module(acc),
          ast_path: path,
          ast_path_hash: path_hash(path),
          node: node
        }

        %{acc | candidates: [candidate | acc.candidates]}

      :error ->
        acc
    end
  end

  defp literal_syntactic_name(value) when is_integer(value), do: :integer_literal
  defp literal_syntactic_name(value) when is_boolean(value), do: :boolean_literal

  defp literal_span(meta, value, acc) do
    with line when is_integer(line) <- Keyword.get(meta, :line),
         column when is_integer(column) <- Keyword.get(meta, :column) do
      token = literal_token(meta, value)
      end_column = column + String.length(token)

      %Mut.SourceSpan{
        file: acc.file,
        start_line: line,
        start_column: column,
        end_line: line,
        end_column: end_column,
        start_byte: byte_offset(acc.source, acc.line_offsets, line, column),
        end_byte: byte_offset(acc.source, acc.line_offsets, line, end_column)
      }
    else
      _missing -> nil
    end
  end

  defp literal_token(meta, value) do
    case Keyword.get(meta, :token) do
      bin when is_binary(bin) and bin != "" -> bin
      _ -> to_string(value)
    end
  end

  # Don't double-traverse the inner literal value — the __block__
  # wrapper IS the candidate; descending into [value] just emits
  # spurious frames.
  defp body_literal_block?({:__block__, _meta, [value]})
       when is_integer(value) or is_boolean(value),
       do: true

  defp body_literal_block?(_), do: false

  defp prune_body_literal({:__block__, meta, [value]})
       when is_integer(value) or is_boolean(value),
       do: {:__block__, meta, []}

  defp prune_body_literal(node), do: prune(node)

  # Body position = inside a def/defp body block, and not inside any
  # refused context (guard, pattern, macro body, quote, attribute
  # value, match LHS, clause head pattern).
  defp body_position?(path) do
    in_function_body?(path) and not refused_body_context?(path)
  end

  defp in_function_body?(path) do
    path
    |> Enum.with_index()
    |> Enum.any?(fn
      # def/defp body lives at args-index 1 of the def node, then
      # inside the kw-list `[do: ...]`. The inner body path includes
      # `{:elem, :def, 1}` or `{:elem, :defp, 1}` somewhere.
      {{:elem, kind, 1}, _} when kind in [:def, :defp] -> true
      _ -> false
    end)
  end

  defp refused_body_context?(path) do
    Enum.any?(path, &match?({:elem, :when, 1}, &1)) or
      Enum.any?(path, &match?({:elem, :@, _}, &1)) or
      Enum.any?(path, fn
        {:elem, kind, _}
        when kind in [:defmacro, :defmacrop, :quote, :unquote, :unquote_splicing] ->
          true

        _ ->
          false
      end) or
      lhs_match_path_walk?(path) or
      clause_head_pattern_path_walk?(path) or
      function_head_walk?(path)
  end

  defp lhs_match_path_walk?(path), do: Enum.any?(path, &match?({:elem, :=, 0}, &1))

  # A `{:elem, :->, 0}` step is the HEAD (left) of a clause. For
  # case / fn / with-else / try-rescue|catch / receive that head is a
  # PATTERN (match position) — a literal there cannot be schema-gated
  # (`case` is not allowed in a match). `cond` is excluded: its clause
  # heads are boolean expressions, so a literal there is a real body
  # position (e.g. the `true` catch-all).
  @pattern_clause_constructs [:case, :fn, :with, :try, :receive]
  @clause_block_kinds [:do_block, :else_block, :rescue_block, :catch_block, :after_block]

  defp clause_head_pattern_path_walk?(path) do
    path
    |> Enum.with_index()
    |> Enum.any?(fn
      {{:elem, :->, 0}, idx} -> pattern_clause_head?(Enum.take(path, idx))
      _ -> false
    end)
  end

  defp pattern_clause_head?(prefix_before_arrow) do
    prefix_before_arrow
    |> Enum.reverse()
    |> Enum.drop_while(fn {:elem, kind, _idx} ->
      kind == :list or kind in @clause_block_kinds
    end)
    |> case do
      [{:elem, construct, _idx} | _rest] -> construct in @pattern_clause_constructs
      _other -> false
    end
  end

  defp function_head_walk?(path) do
    function_head_walk_tail?(Enum.take(path, -1)) or
      function_head_walk_tail?(Enum.take(path, -2))
  end

  defp function_head_walk_tail?([{:elem, parent, 0}])
       when parent in [:def, :defp, :defmacro, :defmacrop],
       do: true

  defp function_head_walk_tail?([{:elem, parent, 0}, {:elem, :when, 0}])
       when parent in [:def, :defp, :defmacro, :defmacrop],
       do: true

  defp function_head_walk_tail?(_), do: false

  defp acc(file, source, line_offsets, span_fallback?) do
    %{
      frames: [],
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      module_stack: [],
      span_fallback?: span_fallback?,
      # M78: stack of enclosing def/defp codegen flags (body has quote/unquote).
      codegen_defs: []
    }
  end

  defp pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = enter_codegen(node, acc)
    acc = maybe_candidate(node, path, acc, nil)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp post(node, acc) do
    acc = pop_frame(node, acc)
    acc = exit_module(node, acc)
    acc = exit_codegen(node, acc)
    {node, acc}
  end

  # M78: track def/defp bodies that build quoted code (quote/unquote present).
  # Only pushed in the dispatch `pre`; `exit_codegen` is in the shared `post`
  # but only pops when the acc actually carries a codegen stack (other walks'
  # accs without `:codegen_defs` fall through untouched).
  defp enter_codegen({kind, _meta, [_head, body]}, %{codegen_defs: stack} = acc)
       when kind in [:def, :defp],
       do: %{acc | codegen_defs: [codegen_body?(body) | stack]}

  defp enter_codegen(_node, acc), do: acc

  defp exit_codegen({kind, _meta, [_head, _body]}, %{codegen_defs: [_top | rest]} = acc)
       when kind in [:def, :defp],
       do: %{acc | codegen_defs: rest}

  defp exit_codegen(_node, acc), do: acc

  @codegen_forms ~w(quote unquote unquote_splicing)a
  defp codegen_body?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {form, _meta, _args} = node, _acc when form in @codegen_forms -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp in_codegen?(%{codegen_defs: stack}), do: Enum.any?(stack)
  defp in_codegen?(_acc), do: false

  defp attribute_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = maybe_attribute_candidate(node, path, acc)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp guard_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = enter_module(node, acc)
    acc = maybe_guard_candidates(node, path, acc)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp enter_path(_node, %{frames: []} = acc), do: {[], acc}

  defp enter_path(_node, %{frames: [parent | rest]} = acc) do
    path = parent.path ++ [{:elem, parent.kind, parent.next_index}]
    {path, %{acc | frames: [%{parent | next_index: parent.next_index + 1} | rest]}}
  end

  defp push_frame(node, path, acc) do
    %{acc | frames: [%{kind: node_kind(node), path: path, next_index: 0} | acc.frames]}
  end

  defp pop_frame(_node, %{frames: [_frame | rest]} = acc), do: %{acc | frames: rest}

  defp maybe_candidate(node, path, acc, env_context) do
    case dispatch_shape(node) do
      {:ok, name, arity, meta} ->
        if ignored_path?(path),
          do: acc,
          else:
            add_candidate(
              acc,
              node,
              path,
              name,
              syntactic_arity(node, path, arity),
              meta,
              env_context
            )

      :skip ->
        acc
    end
  end

  defp maybe_attribute_candidate({:@, attr_meta, [{name, meta, [value]}]}, path, acc)
       when is_atom(name) do
    cond do
      name in @reserved_attributes ->
        acc

      not direct_module_attribute_path?(path) ->
        acc

      function_body_path?(path) ->
        acc

      not literal?(value) ->
        acc

      true ->
        add_attribute_candidate(acc, value, path, name, value_meta(value, meta), attr_meta)
    end
  end

  defp maybe_attribute_candidate(_node, _path, acc), do: acc

  defp maybe_guard_candidates({:when, _meta, [_pattern, guard]}, path, acc) do
    frame = %{kind: :when, path: path, next_index: 1}
    guard_acc = %{acc | frames: [frame], candidates: []}
    {_guard, guard_acc} = Macro.traverse(guard, guard_acc, &guard_dispatch_pre/2, &post/2)
    %{acc | candidates: Enum.reverse(guard_acc.candidates) ++ acc.candidates}
  end

  defp maybe_guard_candidates(_node, _path, acc), do: acc

  defp guard_dispatch_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_candidate(node, path, acc, :guard)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp add_candidate(acc, node, path, name, arity, meta, env_context) do
    case Keyword.fetch(meta, :line) do
      {:ok, line} ->
        fallback_span = fallback_source_text_span(node, meta, acc)

        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: Keyword.get(meta, :column),
          syntactic_name: name,
          syntactic_arity: arity,
          source_span:
            fallback_span || Compute.from_meta(meta, acc.source, acc.file, acc.line_offsets),
          env_context: env_context,
          enclosing_module: current_module(acc),
          ast_path: path,
          ast_path_hash: path_hash(path),
          node: node,
          in_codegen?: in_codegen?(acc)
        }

        %{acc | candidates: [candidate | acc.candidates]}

      :error ->
        acc
    end
  end

  defp add_attribute_candidate(acc, node, path, name, meta, attr_meta) do
    case Keyword.fetch(attr_meta, :line) do
      {:ok, line} ->
        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: Keyword.get(attr_meta, :column),
          syntactic_name: name,
          syntactic_arity: 0,
          source_span:
            Compute.from_meta(meta, acc.source, acc.file, acc.line_offsets) ||
              attribute_source_span(acc, attr_meta, name),
          env_context: nil,
          enclosing_module: current_module(acc),
          ast_path: path,
          ast_path_hash: path_hash(path),
          node: node
        }

        %{acc | candidates: [candidate | acc.candidates]}

      :error ->
        acc
    end
  end

  defp dispatch_shape({op, meta, [_left, _right]}) when op in @binary_ops,
    do: {:ok, op, 2, meta}

  defp dispatch_shape({op, meta, [_arg]}) when op in @unary_ops,
    do: {:ok, op, 1, meta}

  defp dispatch_shape({:|>, _meta, _args}), do: :skip

  defp dispatch_shape({name, _meta, _args}) when name in @no_descend, do: :skip

  defp dispatch_shape({:., _meta, _args}), do: :skip

  defp dispatch_shape({{:., _dot_meta, [_target, name]}, meta, args})
       when is_atom(name) and is_list(args),
       do: {:ok, name, length(args), meta}

  defp dispatch_shape({{:., _dot_meta, [{name, _var_meta, ctx}]}, meta, args})
       when is_atom(name) and is_atom(ctx) and is_list(args),
       do: {:ok, name, length(args), meta}

  defp dispatch_shape({:__aliases__, _meta, _parts}), do: :skip

  defp dispatch_shape({:__block__, _meta, _parts}), do: :skip

  defp dispatch_shape({:@, _meta, [_attr]}), do: :skip

  defp dispatch_shape({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: :skip

  defp dispatch_shape({name, _meta, _args}) when name in @special_forms, do: :skip

  defp dispatch_shape({name, meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, name, length(args), meta}

  defp dispatch_shape(_node), do: :skip

  defp ignored_path?(path), do: attribute_path?(path) or function_head_path?(path)

  defp syntactic_arity(node, path, arity) do
    if pipe_right_path?(path) and call_node?(node), do: arity + 1, else: arity
  end

  defp pipe_right_path?(path), do: List.last(path) == {:elem, :|>, 1}

  defp call_node?({{:., _dot_meta, [_target, name]}, _meta, args})
       when is_atom(name) and is_list(args),
       do: true

  defp call_node?({name, _meta, args}) when is_atom(name) and is_list(args), do: true
  defp call_node?(_node), do: false

  defp attribute_path?(path), do: Enum.any?(path, &match?({:elem, :@, _index}, &1))

  defp function_body_path?(path),
    do: Enum.any?(path, &match?({:elem, def_kind, _} when def_kind in @function_defs, &1))

  defp direct_module_attribute_path?(path),
    do: Enum.any?(path, &match?({:elem, :defmodule, _}, &1))

  defp function_head_path?(path) do
    function_head_tail?(Enum.take(path, -1)) or function_head_tail?(Enum.take(path, -2))
  end

  defp function_head_tail?([{:elem, parent, 0}])
       when parent in @function_defs,
       do: true

  defp function_head_tail?([{:elem, parent, 0}, {:elem, :when, 0}])
       when parent in @function_defs,
       do: true

  defp function_head_tail?(_tail), do: false

  defp no_descend?({name, _meta, _args}) when name in @no_descend, do: true
  defp no_descend?(_node), do: false

  defp prune({name, meta, _args}), do: {name, meta, []}

  defp enter_module({:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, _body]}, acc) do
    %{acc | module_stack: [Module.concat(parts) | acc.module_stack]}
  end

  defp enter_module(_node, acc), do: acc

  defp exit_module({:defmodule, _meta, _args}, %{module_stack: [_module | rest]} = acc),
    do: %{acc | module_stack: rest}

  defp exit_module(_node, acc), do: acc

  defp current_module(%{module_stack: [module | _rest]}), do: module
  defp current_module(_acc), do: nil

  defp literal?(value) when is_number(value) or is_binary(value) or is_atom(value), do: true
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?({:{}, _meta, values}) when is_list(values), do: Enum.all?(values, &literal?/1)

  defp literal?({:%{}, _meta, pairs}) when is_list(pairs) do
    Enum.all?(pairs, fn {key, value} -> literal?(key) and literal?(value) end)
  end

  defp literal?({_left, _right, _rest}), do: false

  defp literal?(_value), do: false

  defp value_meta({_name, meta, _args}, _attribute_meta) when is_list(meta), do: meta
  defp value_meta(_value, attribute_meta), do: attribute_meta

  defp attribute_source_span(%{source: nil}, _meta, _name), do: nil

  defp attribute_source_span(acc, attr_meta, name) do
    with line when is_integer(line) <- Keyword.get(attr_meta, :line),
         column when is_integer(column) <- Keyword.get(attr_meta, :column),
         end_meta when is_list(end_meta) <- Keyword.get(attr_meta, :end_of_expression),
         end_column when is_integer(end_column) <- Keyword.get(end_meta, :column),
         line_text when is_binary(line_text) <- source_line(acc.source, line),
         {:ok, start_column} <- attribute_value_column(line_text, column, name) do
      %Mut.SourceSpan{
        file: acc.file,
        start_line: line,
        start_column: start_column,
        end_line: line,
        end_column: end_column,
        start_byte: byte_offset(acc.source, acc.line_offsets, line, start_column),
        end_byte: byte_offset(acc.source, acc.line_offsets, line, end_column)
      }
    else
      _missing -> nil
    end
  end

  defp source_line(source, line) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1)
  end

  defp fallback_source_text_span(node, meta, %{span_fallback?: true} = acc),
    do: source_text_span(node, meta, acc)

  defp fallback_source_text_span(_node, _meta, _acc), do: nil

  defp source_text_span(_node, _meta, %{source: nil}), do: nil

  defp source_text_span(node, meta, acc) do
    # Parser metadata can omit end positions for guard operators; require the operator
    # column to fall inside the rendered snippet to avoid same-line duplicate matches.
    with line when is_integer(line) <- Keyword.get(meta, :line),
         column when is_integer(column) <- Keyword.get(meta, :column),
         rendered when rendered != "" <- Macro.to_string(node),
         line_text when is_binary(line_text) <- source_line(acc.source, line),
         {start_column, end_column} <- rendered_span(line_text, rendered, column) do
      %Mut.SourceSpan{
        file: acc.file,
        start_line: line,
        start_column: start_column,
        end_line: line,
        end_column: end_column,
        start_byte: byte_offset(acc.source, acc.line_offsets, line, start_column),
        end_byte: byte_offset(acc.source, acc.line_offsets, line, end_column)
      }
    else
      _missing -> nil
    end
  end

  defp rendered_span(line_text, rendered, column) do
    line_text
    |> :binary.matches(rendered)
    |> Enum.map(fn {start_byte, length} -> {start_byte + 1, start_byte + length + 1} end)
    |> Enum.find(fn {start_column, end_column} ->
      start_column <= column and column <= end_column
    end)
  end

  defp attribute_value_column(line_text, attr_column, name) do
    attr_prefix = "@" <> Atom.to_string(name)
    line_suffix = String.slice(line_text, (attr_column - 1)..-1//1)

    if String.starts_with?(line_suffix, attr_prefix) do
      value_prefix =
        line_suffix |> String.replace_prefix(attr_prefix, "") |> leading_whitespace_length()

      {:ok, attr_column + String.length(attr_prefix) + value_prefix}
    else
      :error
    end
  end

  defp leading_whitespace_length(string) do
    string
    |> String.graphemes()
    |> Enum.take_while(&(&1 in [" ", "\t"]))
    |> length()
  end

  defp byte_offset(source, line_offsets, line, column) do
    line_start = Map.fetch!(line_offsets, line)

    source
    |> binary_part(line_start, byte_size(source) - line_start)
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, column - 1)
    |> byte_size()
    |> Kernel.+(line_start)
  end

  defp span_start_byte(%AstCandidate{source_span: %{start_byte: start_byte}}), do: start_byte
  defp span_start_byte(%AstCandidate{line: line, column: column}), do: {line, column || 0}

  defp node_kind({:__block__, _meta, _args}), do: :do_block
  defp node_kind({name, _meta, _args}) when is_atom(name), do: name
  defp node_kind({{:., _dot_meta, [_target, name]}, _meta, _args}) when is_atom(name), do: name
  defp node_kind({name, _value}) when is_atom(name), do: block_kind(name)
  defp node_kind(list) when is_list(list), do: :list
  defp node_kind(_node), do: :literal

  defp block_kind(:do), do: :do_block
  defp block_kind(:else), do: :else_block
  defp block_kind(:rescue), do: :rescue_block
  defp block_kind(:catch), do: :catch_block
  defp block_kind(:after), do: :after_block
  defp block_kind(name), do: name

  defp path_hash(path) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(path))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end
end
