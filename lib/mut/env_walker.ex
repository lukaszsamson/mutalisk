defmodule Mut.EnvWalker do
  @dialyzer {:no_opaque, [classify_kernel_control_flow: 4]}

  @moduledoc """
  Source-AST walker that classifies nodes for v2 mutators.

  Implements the design from `docs/spikes/M39_env_walker.md`. The
  walker does NOT execute top-level code, evaluate module bodies,
  invoke module callbacks, or expand user macros. It uses syntax
  and an optional tracer-macro index to decide trust.

  ## Public surface

      iex> {:ok, ast} = Mut.EnvWalker.parse_string(source, "lib/foo.ex")
      iex> snapshots = Mut.EnvWalker.collect_literal_snapshots(ast, opts)

  `opts`:

    * `:file` — relative source path used in snapshot fields.
    * `:source` — source text used for `source_span` computation.
    * `:macro_index` — optional `tracer_macro_index` map (see
      `M39_env_walker.md`). When absent, `if` / `unless` are
      conservatively classified as opaque.

  ## Output shape

  `collect_literal_snapshots/2` returns a list of
  `Mut.EnvSnapshot.t/0` records, one per `:__block__`-wrapped
  literal (the AST shape produced by the parser's
  `:literal_encoder` option). Each snapshot has `scope`,
  `context`, and `trust_level` populated according to the
  walker's traversal at that point in the source.

  Non-literal nodes do not produce snapshots in this commit;
  they are added in later milestones if/when mutators outside
  the literal class come online.

  ## Parse mode

  `parse_string/2` wraps `Code.string_to_quoted/2` with:

      [
        file: file,
        columns: true,
        token_metadata: true,
        emit_warnings: false,
        literal_encoder: fn literal, meta ->
          {:ok, {:__block__, meta, [literal]}}
        end
      ]

  The literal-encoded AST is the right input for env-walker
  literal discovery because bare strings, atoms, numbers,
  lists, and booleans otherwise lose parser metadata.

  ## Strict no-expansion contract

  The walker MUST NOT call any of: `Macro.expand`,
  `Macro.expand_once`, `Code.eval_*`, `Code.compile_*`,
  `Kernel.ParallelCompiler`, `:elixir_expand`, `:elixir_module`,
  `:elixir_def`, `Macro.Env.expand_import/5`,
  `Macro.Env.expand_require/6`, `Macro.Env.define_import/4`,
  `Macro.Env.fetch_alias/2`, `Macro.Env.fetch_macro_alias/2`,
  or direct reads of `%Macro.Env{}` private fields. This is
  enforced by a verify-layer grep gate added in M40 commit 7.
  """

  alias Mut.EnvSnapshot
  alias Mut.OpaquePolicy
  alias Mut.Oracle.AstCandidate
  alias Mut.SourceSpan

  @parser_opts [columns: true, token_metadata: true, emit_warnings: false]

  @type tracer_macro_index :: %{
          {
            file :: String.t(),
            line :: pos_integer() | nil,
            column :: pos_integer() | nil,
            name :: atom(),
            arity :: non_neg_integer()
          } => %{
            kind: :local_macro | :remote_macro | :imported_macro,
            resolved_module: module() | nil,
            resolved_name: atom(),
            resolved_arity: non_neg_integer()
          }
        }

  @type collect_opts :: [
          file: Path.t(),
          source: String.t(),
          macro_index: tracer_macro_index() | nil
        ]

  @doc """
  Parses source with the literal-encoder option, returning an AST
  that wraps each literal in `{:__block__, meta, [value]}` so the
  walker can attach metadata-aware snapshots.
  """
  @spec parse_string(source :: String.t(), file :: Path.t()) ::
          {:ok, Macro.t()} | {:error, term()}
  def parse_string(source, file) when is_binary(source) and is_binary(file) do
    opts =
      @parser_opts
      |> Keyword.put(:file, file)
      |> Keyword.put(:literal_encoder, &literal_encoder/2)

    case Code.string_to_quoted(source, opts) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} = err -> err
    end
  end

  defp literal_encoder(literal, meta), do: {:ok, {:__block__, meta, [literal]}}

  @doc """
  Walks the AST and returns `[{Mut.Oracle.AstCandidate.t(),
  Mut.EnvSnapshot.t()}]` pairs for each string literal whose
  snapshot is body-literal-eligible
  (`Mut.EnvSnapshot.body_literal_eligible?/1`).

  This is the candidate-source function the orchestrator wires
  into `env_walker_results/4` for M40's `StringLiteral` mutator.
  Only string-valued literals are returned; integer / boolean /
  atom literals are out of scope for v1.14 first implementation
  (M39 mutator-ordering item 1).
  """
  @spec collect_string_literal_candidates(Macro.t(), collect_opts()) ::
          [{AstCandidate.t(), EnvSnapshot.t()}]
  def collect_string_literal_candidates(ast, opts) when is_list(opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source, "")
    macro_index = Keyword.get(opts, :macro_index)
    line_offsets = compute_line_offsets(source)

    initial_state = %{
      file: file,
      source: source,
      line_offsets: line_offsets,
      macro_index: macro_index,
      ast_path: [],
      module: nil,
      function: nil,
      context: nil,
      scope: :top_level,
      trust_level: :trusted,
      snapshots: [],
      candidates: [],
      literal_kinds: [:string]
    }

    state = walk(ast, initial_state)
    Enum.reverse(state.candidates)
  end

  @doc """
  Walks the AST and returns `[{Mut.Oracle.AstCandidate.t(),
  Mut.EnvSnapshot.t()}]` pairs for every body-literal-eligible
  string, float, and `nil` literal (M44 low-noise literal set).

  This is the candidate source the orchestrator wires in for the
  v1.15 env-walker literal mutators (StringLiteral / FloatLiteral /
  NilLiteral). A candidate is emitted regardless of which mutators
  are enabled; the orchestrator's per-mutator `applicable?/2` filters
  the stream, so an enabled-but-unmatched candidate becomes a skip,
  never a spurious mutant. Integer / boolean body literals stay with
  `Mut.AstWalk.body_literal_candidates/1` (their stable IDs predate
  the env walker).
  """
  @spec collect_literal_candidates(Macro.t(), collect_opts()) ::
          [{AstCandidate.t(), EnvSnapshot.t()}]
  def collect_literal_candidates(ast, opts) when is_list(opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source, "")
    macro_index = Keyword.get(opts, :macro_index)
    line_offsets = compute_line_offsets(source)

    initial_state = %{
      file: file,
      source: source,
      line_offsets: line_offsets,
      macro_index: macro_index,
      ast_path: [],
      module: nil,
      function: nil,
      context: nil,
      scope: :top_level,
      trust_level: :trusted,
      snapshots: [],
      candidates: [],
      literal_kinds: [:string, :float, :nil_lit]
    }

    state = walk(ast, initial_state)
    Enum.reverse(state.candidates)
  end

  @doc """
  Walks the AST and returns a list of `Mut.EnvSnapshot` records
  for each `:__block__`-wrapped literal node.
  """
  @spec collect_literal_snapshots(Macro.t(), collect_opts()) :: [EnvSnapshot.t()]
  def collect_literal_snapshots(ast, opts) when is_list(opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source, "")
    macro_index = Keyword.get(opts, :macro_index)
    line_offsets = compute_line_offsets(source)

    initial_state = %{
      file: file,
      source: source,
      line_offsets: line_offsets,
      macro_index: macro_index,
      ast_path: [],
      module: nil,
      function: nil,
      context: nil,
      scope: :top_level,
      trust_level: :trusted,
      snapshots: [],
      candidates: [],
      literal_kinds: []
    }

    state = walk(ast, initial_state)
    Enum.reverse(state.snapshots)
  end

  ## --- recursive walk ----------------------------------------------------

  defp walk(node, state) do
    state = maybe_emit_literal_snapshot(state, node)
    descend(node, state)
  end

  # Literal block — possible mutation target.
  defp maybe_emit_literal_snapshot(state, {:__block__, meta, [value]} = node)
       when is_list(meta) do
    cond do
      not literal_value?(value) ->
        state

      generated?(meta, state.file) ->
        emit_snapshot(state, meta, :generated)

      true ->
        state
        |> emit_snapshot(meta, state.trust_level)
        |> maybe_emit_literal_candidate(node, value, meta)
    end
  end

  defp maybe_emit_literal_snapshot(state, _node), do: state

  # M40 commit 5 (strings) + M44 (float / nil): surface literal
  # AstCandidates for the env-walker literal mutators. A candidate is
  # emitted only when the value's kind is in `state.literal_kinds`
  # (so `collect_literal_snapshots/2` emits none) AND the snapshot we
  # just emitted is body-literal-eligible.
  defp maybe_emit_literal_candidate(state, node, value, meta) do
    case literal_candidate_name(value, state.literal_kinds) do
      nil ->
        state

      syntactic_name ->
        [latest_snap | _] = state.snapshots

        if EnvSnapshot.body_literal_eligible?(latest_snap) do
          candidate = build_literal_candidate(state, node, meta, latest_snap, syntactic_name)
          %{state | candidates: [{candidate, latest_snap} | state.candidates]}
        else
          state
        end
    end
  end

  defp literal_candidate_name(value, kinds) do
    cond do
      is_binary(value) and value != "" and :string in kinds -> :__string_literal__
      is_float(value) and :float in kinds -> :__float_literal__
      is_nil(value) and :nil_lit in kinds -> :__nil_literal__
      true -> nil
    end
  end

  defp build_literal_candidate(state, node, meta, snap, syntactic_name) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    %AstCandidate{
      file: state.file,
      line: line,
      column: column,
      syntactic_name: syntactic_name,
      syntactic_arity: 0,
      source_span: literal_span(state, meta, snap),
      env_context: nil,
      enclosing_module: state.module,
      ast_path: state.ast_path,
      ast_path_hash: path_hash(state.ast_path),
      node: node
    }
  end

  defp literal_span(state, meta, _snap) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if is_integer(line) and is_integer(column) do
      {end_line, end_column} = literal_end(meta, line, column)

      %SourceSpan{
        file: state.file,
        start_line: line,
        start_column: column,
        end_line: end_line,
        end_column: end_column,
        start_byte: byte_offset(state, line, column),
        end_byte: byte_offset(state, end_line, end_column)
      }
    end
  end

  # `:token` (raw source text) is the cleanest end indicator, but
  # the literal_encoder option does not propagate `:token` for
  # string / atom literals. Fall back to `:end_of_expression` (the
  # newline-trailing marker the parser emits with token_metadata)
  # so different physical sites produce distinct byte spans even
  # when the source value is the same.
  defp literal_end(meta, line, column) do
    cond do
      token = Keyword.get(meta, :token) ->
        if is_binary(token), do: {line, column + String.length(token)}, else: {line, column + 1}

      end_of_expr = Keyword.get(meta, :end_of_expression) ->
        {Keyword.get(end_of_expr, :line, line), Keyword.get(end_of_expr, :column, column + 1)}

      true ->
        {line, column + 1}
    end
  end

  defp byte_offset(state, line, column) do
    case Enum.at(state.line_offsets, line - 1) do
      nil -> nil
      base -> base + column - 1
    end
  end

  defp path_hash(path) do
    # Mirror Mut.AstWalk.path_hash/1: 16-byte SHA-256 prefix, base-16
    # lower-cased. The hex encoding keeps the value JSON-safe (some
    # raw binary hashes contain bytes that elixir_json refuses as
    # UTF-8).
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(path))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp literal_value?(value) when is_binary(value), do: true
  defp literal_value?(value) when is_atom(value), do: true
  defp literal_value?(value) when is_number(value), do: true
  defp literal_value?(_), do: false

  defp emit_snapshot(state, meta, trust_level) do
    snap = %EnvSnapshot{
      file: state.file,
      line: Keyword.get(meta, :line),
      column: Keyword.get(meta, :column),
      source_span: nil,
      ast_path: state.ast_path,
      ast_path_hash: nil,
      module: state.module,
      function: state.function,
      context: state.context,
      scope: state.scope,
      trust_level: trust_level
    }

    %{state | snapshots: [snap | state.snapshots]}
  end

  defp generated?(meta, file) do
    Keyword.get(meta, :generated, false) == true or
      generated_file?(meta, file)
  end

  defp generated_file?(meta, file) do
    case Keyword.get(meta, :file) do
      nil -> false
      ^file -> false
      _other -> true
    end
  end

  # `defmodule M do body end`
  defp descend({:defmodule, _meta, [module_ast, kw]}, state) when is_list(kw) do
    body = fetch_block(kw, :do)
    module = resolve_module_alias(module_ast, state.module)
    inner = %{state | module: module, scope: :module_body, function: nil, context: nil}
    inner = walk(body, inner)
    %{state | snapshots: inner.snapshots, candidates: inner.candidates}
  end

  # `def name(...) [when ...] do body end` and friends.
  defp descend({kind, _meta, [head, kw]}, state)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] and is_list(kw) do
    body = fetch_block(kw, :do)
    walk_def(kind, head, body, state)
  end

  # `def name(...)` headless — no body.
  defp descend({kind, _meta, [_head]}, state)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    state
  end

  # `fn ... -> ... end` — clauses with patterns + bodies.
  defp descend({:fn, _meta, clauses}, state) when is_list(clauses) do
    walk_clauses(clauses, state)
  end

  # `case expr do ... end`.
  defp descend({:case, _meta, [expr, kw]}, state) when is_list(kw) do
    state = walk(expr, state)
    clauses = fetch_block(kw, :do)
    walk_clauses(clauses, state)
  end

  # `cond do ... end` — clauses are `expr -> body`; expressions are in normal context.
  defp descend({:cond, _meta, [kw]}, state) when is_list(kw) do
    clauses = fetch_block(kw, :do)

    Enum.reduce(List.wrap(clauses), state, fn
      {:->, _, [[expr], body]}, acc ->
        acc = walk(expr, acc)
        walk(body, acc)

      _, acc ->
        acc
    end)
  end

  # `with ... <- ... do ... end` and `else: clauses`.
  defp descend({:with, _meta, args}, state) when is_list(args) do
    walk_with(args, state)
  end

  # `for ... <- ... do ... end`.
  defp descend({:for, _meta, args}, state) when is_list(args) do
    walk_for(args, state)
  end

  # `receive do ... end` and `receive do ... after ... end`.
  defp descend({:receive, _meta, [kw]}, state) when is_list(kw) do
    state = walk_clauses(List.wrap(fetch_block(kw, :do)), state)

    case fetch_block(kw, :after) do
      nil -> state
      after_clauses -> walk_clauses(List.wrap(after_clauses), state)
    end
  end

  # `try do ... end`.
  defp descend({:try, _meta, [kw]}, state) when is_list(kw) do
    walk_try(kw, state)
  end

  # `quote do ... end` — quoted boundary.
  defp descend({:quote, _meta, _args}, state) do
    state
  end

  # `= match expr`.
  defp descend({:=, _meta, [lhs, rhs]}, state) do
    state = walk(rhs, state)
    walk_in_context(lhs, state, :match)
  end

  # `when ...` — top-level `when` outside def is a guard expression.
  defp descend({:when, _meta, [head, guard]}, state) do
    state = walk(head, state)
    walk_in_context(guard, state, :guard)
  end

  # `^pinned`.
  defp descend({:^, _meta, [child]}, state) do
    # Pin operator: pinned expression is evaluated outside match context.
    walk_in_context(child, state, nil)
  end

  # `&function/arity` capture — body of capture stays in normal context.
  defp descend({:&, _meta, args}, state), do: descend_args(args, state)

  # Generic call node.
  defp descend({name, meta, args}, state) when is_atom(name) and is_list(args) do
    classify_call(name, meta, args, state)
  end

  # Two-tuple (e.g. {:do, body} keyword entries).
  defp descend({_a, _b}, state), do: state

  # List of children.
  defp descend(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk(&1, &2))
  end

  # Leaves.
  defp descend(_other, state), do: state

  defp descend_args(args, state) when is_list(args) do
    Enum.reduce(args, state, &walk(&1, &2))
  end

  ## --- per-form helpers --------------------------------------------------

  defp walk_def(kind, head, body, state) do
    function = function_name_arity(head)

    head_state =
      %{
        state
        | function: function,
          scope: :function_head,
          context: :match,
          trust_level: :trusted
      }

    {head_args, head_state} = split_head(head, head_state)
    head_state = walk_head_args(head_args, head_state)

    body_scope = body_scope_for(kind)

    body_context =
      case kind do
        k when k in [:defguard, :defguardp] -> :guard
        _ -> nil
      end

    body_state = %{head_state | scope: body_scope, context: body_context}
    body_state = walk(body, body_state)

    %{state | snapshots: body_state.snapshots, candidates: body_state.candidates}
  end

  defp body_scope_for(:defmacro), do: :macro_definition
  defp body_scope_for(:defmacrop), do: :macro_definition
  defp body_scope_for(_), do: :function_body

  # Decompose `head` into args + optional guard. Returns `{args, state_after_guard}`.
  defp split_head({:when, _meta, [inner, guard]}, state) do
    {args, state_after_args} = split_head(inner, state)
    state_after_guard = walk_in_context(guard, state_after_args, :guard)
    {args, state_after_guard}
  end

  defp split_head({_name, _meta, args}, state) when is_list(args), do: {args, state}
  defp split_head({_name, _meta, nil}, state), do: {[], state}
  defp split_head(_other, state), do: {[], state}

  defp walk_head_args(args, state) do
    Enum.reduce(args, state, fn arg, acc ->
      case arg do
        {:\\, _meta, [pattern, default]} ->
          acc = walk_in_context(pattern, acc, :match)
          walk_in_context(default, acc, nil)

        other ->
          walk_in_context(other, acc, :match)
      end
    end)
  end

  defp walk_clauses(clauses, state) when is_list(clauses) do
    Enum.reduce(clauses, state, fn
      {:->, _meta, [head, body]}, acc ->
        head_state = walk_clause_head(head, %{acc | context: :match})
        body_state = %{head_state | context: nil}
        body_state = walk(body, body_state)
        %{acc | snapshots: body_state.snapshots, candidates: body_state.candidates}

      _, acc ->
        acc
    end)
  end

  defp walk_clauses(_, state), do: state

  defp walk_clause_head([{:when, _, [pattern, guard]}], state) do
    state = walk_in_context(pattern, state, :match)
    walk_in_context(guard, state, :guard)
  end

  defp walk_clause_head(patterns, state) when is_list(patterns) do
    Enum.reduce(patterns, state, &walk_in_context(&1, &2, :match))
  end

  defp walk_with(args, state) do
    case List.last(args) do
      kw when is_list(kw) ->
        clauses = Enum.drop(args, -1)
        state = Enum.reduce(clauses, state, &walk_with_clause/2)
        do_body = fetch_block(kw, :do)
        else_clauses = fetch_block(kw, :else)
        state = if do_body, do: walk(do_body, state), else: state
        if else_clauses, do: walk_clauses(List.wrap(else_clauses), state), else: state

      _ ->
        Enum.reduce(args, state, &walk_with_clause/2)
    end
  end

  defp walk_with_clause({:<-, _meta, [pattern, expr]}, state) do
    state = walk(expr, state)
    walk_in_context(pattern, state, :match)
  end

  defp walk_with_clause(other, state), do: walk(other, state)

  defp walk_for(args, state) do
    case List.last(args) do
      kw when is_list(kw) ->
        clauses = Enum.drop(args, -1)
        state = Enum.reduce(clauses, state, &walk_for_clause/2)
        do_body = fetch_block(kw, :do)
        if do_body, do: walk(do_body, state), else: state

      _ ->
        Enum.reduce(args, state, &walk_for_clause/2)
    end
  end

  defp walk_for_clause({:<-, _meta, [pattern, expr]}, state) do
    state = walk(expr, state)
    walk_in_context(pattern, state, :match)
  end

  defp walk_for_clause(other, state), do: walk(other, state)

  defp walk_try(opts, state) do
    state = if body = fetch_block(opts, :do), do: walk(body, state), else: state

    state =
      if clauses = fetch_block(opts, :rescue),
        do: walk_clauses(List.wrap(clauses), state),
        else: state

    state =
      if clauses = fetch_block(opts, :catch),
        do: walk_clauses(List.wrap(clauses), state),
        else: state

    state =
      if clauses = fetch_block(opts, :else),
        do: walk_clauses(List.wrap(clauses), state),
        else: state

    if body = fetch_block(opts, :after), do: walk(body, state), else: state
  end

  ## --- call classification -----------------------------------------------

  defp classify_call(name, meta, args, state) do
    cond do
      OpaquePolicy.known_special_form?(name) ->
        descend_args(args, state)

      OpaquePolicy.kernel_control_flow?(name) ->
        classify_kernel_control_flow(name, meta, args, state)

      true ->
        classify_user_call(name, meta, args, state)
    end
  end

  defp classify_kernel_control_flow(name, meta, args, state) do
    node = {name, meta, args}

    snap = %EnvSnapshot{
      file: state.file,
      scope: state.scope,
      context: state.context,
      trust_level: state.trust_level
    }

    if OpaquePolicy.trusted_kernel_control_flow?(node, state.macro_index, snap) do
      descend_args(args, state)
    else
      walk_in_trust(args, state, :untrusted_descendant, :opaque_macro)
    end
  end

  defp classify_user_call(_name, _meta, args, %{scope: :module_body} = state) do
    # Module-body calls outside the special-form table are opaque.
    walk_in_trust(args, state, :untrusted_descendant, :opaque_macro)
  end

  defp classify_user_call(_name, _meta, args, state) do
    # Function-body call to an unknown function/macro. We don't have
    # tracer-side proof here in M40 commit 2; conservatively descend
    # in current scope/context without trust changes. The opaque
    # boundary classification refines in commit 4 (defguard/if/unless)
    # and beyond.
    descend_args(args, state)
  end

  defp walk_in_context(node, state, context) do
    inner = walk(node, %{state | context: context})
    %{state | snapshots: inner.snapshots, candidates: inner.candidates}
  end

  defp walk_in_trust(args, state, descendant_trust, descendant_scope) do
    inner =
      Enum.reduce(
        args,
        %{state | trust_level: descendant_trust, scope: descendant_scope},
        &walk(&1, &2)
      )

    %{state | snapshots: inner.snapshots, candidates: inner.candidates}
  end

  ## --- helpers -----------------------------------------------------------

  # The literal_encoder option wraps keyword keys as `{:__block__, _, [:atom]}`.
  # Pattern-matching `[do: body]` no longer works after encoding; use this
  # helper to fetch the value associated with a logical keyword key.
  defp fetch_block(kw, key) when is_list(kw) and is_atom(key) do
    Enum.find_value(kw, fn
      {^key, value} -> value
      {{:__block__, _, [^key]}, value} -> value
      _ -> nil
    end)
  end

  defp fetch_block(_, _), do: nil

  defp function_name_arity({:when, _meta, [inner, _guard]}), do: function_name_arity(inner)

  defp function_name_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp function_name_arity({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp function_name_arity(_), do: nil

  defp resolve_module_alias({:__aliases__, _meta, parts}, _current) when is_list(parts),
    do: Module.concat(parts)

  defp resolve_module_alias(_, current), do: current

  defp compute_line_offsets(""), do: [0]

  defp compute_line_offsets(source) do
    {offsets, _} =
      source
      |> :binary.matches("\n")
      |> Enum.reduce({[0], 0}, fn {pos, _}, {acc, _} -> {[pos + 1 | acc], pos + 1} end)

    Enum.reverse(offsets)
  end
end
