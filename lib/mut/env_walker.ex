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

  # M54: variable-shaped AST nodes (`{name, meta, atom}`) that are NOT
  # mutable bindings/references — the reserved nullary macros.
  @reserved_vars ~w(__MODULE__ __DIR__ __ENV__ __CALLER__ __STACKTRACE__ __block__ __aliases__)a

  # M56: type-determining operators/functions whose DIRECT operands carry a
  # syntactic type hint for the VariableToLiteral mutator. Unambiguous LOCAL
  # forms only (remote calls like `String.length/1` are not walked yet — see
  # the descent-gap note in docs/decisions/M56). Strict boolean `and`/`or`/`not`
  # require boolean operands; `&&`/`||`/`!` (truthy-any) are excluded.
  @number_hint_ops ~w(+ - * / abs round trunc ceil floor)a
  @binary_hint_ops ~w(<> byte_size bit_size)a
  @list_hint_ops ~w(++ -- length hd tl)a
  @boolean_hint_ops ~w(and or not)a

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
      literal_kinds: [:string, :float, :nil_lit, :atom, :collection]
    }

    state = walk(ast, initial_state)
    Enum.reverse(state.candidates)
  end

  @doc """
  M54: walks the AST and returns `[{AstCandidate.t(), EnvSnapshot.t()}]`
  pairs for every in-scope variable *reference* (read) in a trusted
  function body, where at least one other in-scope variable exists to swap
  to. Each candidate's `bound_vars` lists the alternatives (sorted).

  In-scope is a deliberate under-approximation: function parameters plus
  enclosing case/fn/receive/try clause-head bindings (NOT body `=` or
  with/for generators), all of which are unconditionally in scope at the
  reference, so a swap never introduces an undefined variable.
  """
  @spec collect_variable_candidates(Macro.t(), collect_opts()) ::
          [{AstCandidate.t(), EnvSnapshot.t()}]
  def collect_variable_candidates(ast, opts) when is_list(opts) do
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
      literal_kinds: [],
      bound_vars: MapSet.new(),
      emit_variables: true
    }

    state = walk(ast, initial_state)
    state.candidates |> Enum.reverse() |> mark_other_uses()
  end

  # M57: a variable's swap is "safe" from unused-variable churn iff the name has
  # >=1 OTHER read in the same function. Count read-candidates per
  # {module, function, name}; mark `other_uses?` true when the name appears >=2
  # times. Gates VariableReplace (VariableToLiteral ignores it).
  defp mark_other_uses(pairs) do
    counts =
      Enum.reduce(pairs, %{}, fn {candidate, snap}, acc ->
        Map.update(acc, use_key(candidate, snap), 1, &(&1 + 1))
      end)

    Enum.map(pairs, fn {candidate, snap} ->
      {%{candidate | other_uses?: Map.fetch!(counts, use_key(candidate, snap)) >= 2}, snap}
    end)
  end

  defp use_key(%AstCandidate{node: {name, _meta, _ctx}}, snap),
    do: {snap.module, snap.function, name}

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
      literal_value?(value) and generated?(meta, state.file) ->
        emit_snapshot(state, meta, :generated)

      literal_value?(value) ->
        state
        |> emit_snapshot(meta, state.trust_level)
        |> maybe_emit_literal_candidate(node, value, meta)

      # M45: list / 2-tuple literals are wrapped by the literal_encoder
      # (structural keyword-list args and do-blocks are NOT), so a
      # wrapped collection value is always a genuine source literal.
      collection_literal?(value) and not generated?(meta, state.file) ->
        maybe_emit_collection_candidate(state, node, value, meta)

      true ->
        state
    end
  end

  defp maybe_emit_literal_snapshot(state, _node), do: state

  # M40 commit 5 (strings) + M44 (float / nil): surface literal
  # AstCandidates for the env-walker literal mutators. A candidate is
  # emitted only when the value's kind is in `state.literal_kinds`
  # (so `collect_literal_snapshots/2` emits none) AND the snapshot we
  # just emitted is body-literal-eligible.
  defp maybe_emit_literal_candidate(state, node, value, meta) do
    [latest_snap | _] = state.snapshots

    cond do
      # The variable walk (collect_variable_candidates/2) emits only variable
      # candidates; literal candidates must not leak into it.
      Map.get(state, :emit_variables, false) ->
        state

      EnvSnapshot.body_literal_eligible?(latest_snap) ->
        case literal_candidate_name(value, state.literal_kinds) do
          nil -> state
          name -> emit_literal_candidate(state, node, meta, latest_snap, name, nil)
        end

      # M53: literals in `:match` (pattern) positions, fallback-routed under
      # the opt-in `:pattern_literal` target. `descend/2` never recurses into
      # 2-tuples or map pairs and the walker tracks no positional path, so the
      # discoverable surface is naturally conservative (bare args, list /
      # n-tuple elements). The one structural hazard is a bitstring segment
      # size (`<<x::16>>`), where a literal swap can produce an invalid match
      # -- `match_literal_candidate?/2` skips those.
      match_literal_candidate?(latest_snap, state) ->
        case match_literal_name(value) do
          nil -> state
          name -> emit_literal_candidate(state, node, meta, latest_snap, name, :match)
        end

      true ->
        state
    end
  end

  defp emit_literal_candidate(state, node, meta, snap, syntactic_name, env_context) do
    candidate = build_literal_candidate(state, node, meta, snap, syntactic_name, env_context)
    %{state | candidates: [{candidate, snap} | state.candidates]}
  end

  defp match_literal_candidate?(snap, state) do
    snap.context == :match and snap.trust_level == :trusted and
      not Map.get(state, :in_bitstring, false)
  end

  # M53 pattern-position literal subset: integer / boolean / nil / atom /
  # string (NOT float -- floats in patterns are rare and noisy). `is_boolean`
  # and `is_nil` precede `is_atom`; `is_integer` excludes floats.
  defp match_literal_name(value) do
    cond do
      is_boolean(value) -> :__boolean_literal__
      is_nil(value) -> :__nil_literal__
      is_integer(value) -> :__integer_literal__
      is_binary(value) and value != "" -> :__string_literal__
      is_atom(value) -> :__atom_literal__
      true -> nil
    end
  end

  defp literal_candidate_name(value, kinds) do
    cond do
      string_candidate?(value, kinds) -> :__string_literal__
      is_float(value) and :float in kinds -> :__float_literal__
      is_nil(value) and :nil_lit in kinds -> :__nil_literal__
      atom_candidate?(value, kinds) -> :__atom_literal__
      true -> nil
    end
  end

  defp string_candidate?(value, kinds), do: is_binary(value) and value != "" and :string in kinds

  defp atom_candidate?(value, kinds),
    do: is_atom(value) and value not in [true, false, nil] and :atom in kinds

  # M45 collection candidates. List / 2-tuple literals do not produce a
  # snapshot (only scalars do, to keep `collect_literal_snapshots/2`
  # unchanged); eligibility is read directly from state, which matches
  # `EnvSnapshot.body_literal_eligible?/1` on a state-derived snapshot.
  defp maybe_emit_collection_candidate(state, node, value, meta) do
    cond do
      :collection not in state.literal_kinds ->
        state

      not body_eligible?(state) ->
        state

      true ->
        name = if is_list(value), do: :__list_literal__, else: :__tuple_literal__
        candidate = build_collection_candidate(state, node, meta, name)
        %{state | candidates: [{candidate, state_snapshot(state)} | state.candidates]}
    end
  end

  defp collection_literal?(value) when is_list(value), do: value != []
  defp collection_literal?(value) when is_tuple(value) and tuple_size(value) == 2, do: true
  defp collection_literal?(_), do: false

  defp body_eligible?(state) do
    state.scope == :function_body and state.context == nil and state.trust_level == :trusted
  end

  defp state_snapshot(state) do
    %EnvSnapshot{
      file: state.file,
      module: state.module,
      function: state.function,
      context: state.context,
      scope: state.scope,
      trust_level: state.trust_level,
      bound_vars: current_bound_vars(state)
    }
  end

  defp build_literal_candidate(
         state,
         {:__block__, _m, [value]} = node,
         meta,
         _snap,
         syntactic_name,
         env_context
       ) do
    %AstCandidate{
      file: state.file,
      line: Keyword.get(meta, :line),
      column: Keyword.get(meta, :column),
      syntactic_name: syntactic_name,
      syntactic_arity: 0,
      source_span: literal_span(state, meta, value),
      env_context: env_context,
      enclosing_module: state.module,
      ast_path: state.ast_path,
      ast_path_hash: path_hash(state.ast_path),
      node: node
    }
  end

  # M46: the span must cover the FULL literal so the fallback patch
  # splices the right byte range. Numbers carry `:token` (length known);
  # strings / quoted atoms carry only `:delimiter` (scan to the matching
  # close); bare atoms / `nil` / `true` / `false` carry neither (the
  # source length is derivable from the value). The pre-M46 code fell to
  # a 1-char span for the delimiter/bare cases, which produced invalid
  # (string) or garbage (atom/nil) mutations.
  defp literal_span(state, meta, value) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    # Compute `start_byte` only after `line`/`column` are confirmed integers:
    # `byte_offset/3` does arithmetic on them, so calling it first would make
    # dialyzer treat the `is_integer/1` guards below as always-true.
    with true <- is_integer(line) and is_integer(column),
         start_byte when is_integer(start_byte) <- byte_offset(state, line, column) do
      end_byte = literal_end_byte(state.source, start_byte, meta, value)
      {end_line, end_column} = byte_to_line_col(state.line_offsets, end_byte)

      %SourceSpan{
        file: state.file,
        start_line: line,
        start_column: column,
        end_line: end_line,
        end_column: end_column,
        start_byte: start_byte,
        end_byte: end_byte
      }
    else
      _ -> nil
    end
  end

  defp literal_end_byte(source, start_byte, meta, value) do
    cond do
      token = Keyword.get(meta, :token) ->
        start_byte + byte_size(to_string(token))

      delimiter = Keyword.get(meta, :delimiter) ->
        scan_delimited_end(source, start_byte, delimiter)

      is_atom(value) ->
        # `:ok` is `:` + atom text; `nil` / `true` / `false` are the bare
        # word. Both are derivable from the value with no escapes.
        prefix = if value in [nil, true, false], do: 0, else: 1
        start_byte + prefix + byte_size(Atom.to_string(value))

      true ->
        start_byte + 1
    end
  end

  defp scan_delimited_end(source, start_byte, delimiter) do
    dsize = byte_size(delimiter)
    scan_delimiter_close(source, start_byte + dsize, delimiter, dsize)
  end

  defp scan_delimiter_close(source, pos, delimiter, dsize) do
    cond do
      pos + dsize > byte_size(source) ->
        byte_size(source)

      binary_part(source, pos, dsize) == delimiter ->
        pos + dsize

      binary_part(source, pos, 1) == "\\" ->
        scan_delimiter_close(source, pos + 2, delimiter, dsize)

      true ->
        scan_delimiter_close(source, pos + 1, delimiter, dsize)
    end
  end

  defp byte_to_line_col(line_offsets, byte) do
    line_index =
      line_offsets
      |> Enum.take_while(&(&1 <= byte))
      |> length()
      |> max(1)

    offset = Enum.at(line_offsets, line_index - 1, 0)
    {line_index, byte - offset + 1}
  end

  defp build_collection_candidate(state, node, meta, syntactic_name) do
    %AstCandidate{
      file: state.file,
      line: Keyword.get(meta, :line),
      column: Keyword.get(meta, :column),
      syntactic_name: syntactic_name,
      syntactic_arity: 0,
      source_span: collection_span(state, meta),
      env_context: nil,
      enclosing_module: state.module,
      ast_path: state.ast_path,
      ast_path_hash: path_hash(state.ast_path),
      node: node
    }
  end

  # Collections close with a bracket/brace whose position the parser
  # records under `:closing` — the precise span end. The fallback patch
  # splices this byte range, so it must cover the whole literal.
  defp collection_span(state, meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if is_integer(line) and is_integer(column) do
      {end_line, end_column} =
        case Keyword.get(meta, :closing) do
          closing when is_list(closing) ->
            {Keyword.get(closing, :line, line), Keyword.get(closing, :column, column) + 1}

          _ ->
            {line, column + 1}
        end

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

  defp byte_offset(state, line, column) do
    case Enum.at(state.line_offsets, line - 1) do
      nil ->
        nil

      base ->
        # The parser emits CODEPOINT columns, but `base` is a BYTE offset.
        # Adding `column - 1` directly is only correct for ASCII; on a line
        # with a multi-byte char before the target, every byte offset would
        # shift left, corrupting fallback patches and drifting stable IDs.
        # Slice the first `column - 1` codepoints of the line and count their
        # bytes — mirrors `Mut.SourceSpan.Compute.first_codepoints_bytes/2`.
        line_text =
          state.source
          |> binary_part(base, byte_size(state.source) - base)
          |> String.split("\n", parts: 2)
          |> hd()

        base + first_codepoints_bytes(line_text, column - 1)
    end
  end

  defp first_codepoints_bytes(_line, count) when count <= 0, do: 0

  defp first_codepoints_bytes(line, count) do
    line |> String.slice(0, count) |> byte_size()
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

  # `&fun/arity` named capture: `fun` is a function reference (not a variable)
  # and `arity` an integer that must not change. Don't descend — emitting `fun`
  # as a variable read produced undefined-function mutants (`&check/1`).
  defp descend({:&, _meta, [{:/, _, [_fun, _arity]}]}, state), do: state

  # `&(...)` anonymous capture — body stays in normal context.
  defp descend({:&, _meta, args}, state), do: descend_args(args, state)

  # Pipe: `lhs |> rhs`. A bare-identifier rhs (`x |> to_string`) is a FUNCTION
  # call (`to_string(x)`), not a variable read — skip it (swapping it produced
  # undefined-function mutants). A `rhs` with arguments (`x |> f(y)`) or a
  # nested pipe is walked normally so inner candidates are still found.
  defp descend({:|>, _meta, [lhs, rhs]}, state) do
    state = walk(lhs, state)

    case rhs do
      {name, _meta, ctx} when is_atom(name) and is_atom(ctx) -> state
      _other -> walk(rhs, state)
    end
  end

  # M50 struct exclusion: `%S{...}` is NEVER emptied. In a body-eligible
  # position, descend the alias and the field pairs directly so the inner
  # `%{}` never reaches `classify_call(:%{}, …)` (which would emit a map
  # candidate). This matches the generic path's descent for candidates —
  # field pairs are 2-tuple leaves either way. In non-eligible positions
  # the map candidate is never emitted anyway, so they fall through.
  defp descend(
         {:%, _meta, [aliasexpr, {:%{}, _m, pairs}]},
         %{scope: :function_body, context: nil, trust_level: :trusted} = state
       )
       when is_list(pairs) do
    state = walk(aliasexpr, state)
    descend_args(pairs, state)
  end

  # Everything above is a binding-scope / special-form construct. Plain
  # expression, collection, variable, and leaf nodes are handled by
  # `descend_expr/2` — split out only to keep each function's cyclomatic
  # complexity in check (M108/CRAP); the clause order across the two is
  # identical to one flat dispatch, so behavior is unchanged.
  defp descend(node, state), do: descend_expr(node, state)

  # Generic call node.
  defp descend_expr({name, meta, args}, state) when is_atom(name) and is_list(args) do
    classify_call(name, meta, args, state)
  end

  # Two-tuple (e.g. {:do, body} keyword entries).
  defp descend_expr({_a, _b}, state), do: state

  # List of children.
  defp descend_expr(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk(&1, &2))
  end

  # M54: variable node. `{name, meta, ctx}` with an atom context is a
  # variable (calls carry a list as the third element). Emitting is gated on
  # `emit_variables` so literal/dispatch walks are unaffected (variables were
  # already leaves for them).
  defp descend_expr({name, meta, ctx} = node, state) when is_atom(name) and is_atom(ctx) do
    maybe_emit_variable_candidate(state, node, name, meta)
  end

  # Leaves.
  defp descend_expr(_other, state), do: state

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

    # M54: function parameters are bound for the whole body. Clause-local
    # bindings revert when this `def` returns (we thread only snapshots /
    # candidates back onto the outer `state`).
    # M57: a function whose body builds quoted code (`quote`/`unquote`) is a
    # codegen function — mutating its variables tends to break the generated
    # code in dependents (gettext/plug error tail, credo for/unquote). Suppress
    # variable candidates inside it; the flag reverts with the body walk.
    body_state =
      %{head_state | scope: body_scope, context: body_context}
      |> add_bound_vars(head_args)
      |> Map.put(:in_codegen, codegen_body?(body))

    body_state = walk(body, body_state)

    %{state | snapshots: body_state.snapshots, candidates: body_state.candidates}
  end

  @codegen_forms ~w(quote unquote unquote_splicing)a
  defp codegen_body?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {form, _meta, _args} = node, _acc when form in @codegen_forms -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
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
        # M54: clause-head patterns are bound for this clause body only;
        # restoring `acc`'s `bound_vars` on return keeps them clause-local.
        body_state = add_bound_vars(%{head_state | context: nil}, clause_head_patterns(head))
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

  ## --- M54 binding-scope tracking + variable candidates -----------------

  defp add_bound_vars(state, ast) do
    Map.put(state, :bound_vars, MapSet.union(current_bound_vars(state), pattern_vars(ast)))
  end

  defp current_bound_vars(state), do: Map.get(state, :bound_vars, MapSet.new())

  # A clause head is `[patterns...]` or `[{:when, _, [pattern..., guard]}]`.
  # A `when` node's last element is the guard; everything before it is a
  # binding pattern. Drop the guard so guard-referenced names (which are reads,
  # not bindings) never reach `pattern_vars/1` — handles multi-arg `fn`/`def`
  # clause heads, not just the single-pattern shape.
  defp clause_head_patterns([{:when, _meta, parts}]) when is_list(parts) and parts != [],
    do: Enum.drop(parts, -1)

  defp clause_head_patterns(patterns), do: patterns

  # Variable names bound by a pattern (or list of patterns). Pins (`^x` reads
  # an existing binding) and `_`-prefixed / reserved names are excluded.
  defp pattern_vars(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:^, _meta, [_pinned]}, acc ->
          # Replace the pin with a leaf so prewalk does not bind the pinned var.
          {:__mut_pin__, acc}

        {:"::", meta, [left, _spec]}, acc ->
          # Bitstring segment: only the left side binds a variable. The right
          # side is a size/type specifier (`<<rest::bits>>` -> `bits`) which is
          # AST-shaped as a variable but is NOT a binding; neutralize it so it
          # is never collected or offered as a swap target.
          {{:"::", meta, [left, :__mut_spec__]}, acc}

        {:\\, meta, [param, _default]}, acc ->
          # Default argument `param \\ expr`: only `param` binds. The default
          # expression is NOT a binding and may contain identifiers that are
          # not in-scope variables (`@attr` -> bare `attr`, 0-arity calls);
          # collecting them would offer undefined-variable swap targets.
          {{:\\, meta, [param, :__mut_default__]}, acc}

        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if bindable_var?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp bindable_var?(name) do
    not String.starts_with?(Atom.to_string(name), "_") and name not in @reserved_vars
  end

  # Walk operator operands threading a one-shot type hint, restoring the prior
  # hint afterward so it never leaks past this operator node.
  defp walk_operands_hinted(args, hint, state) when is_list(args) do
    prior = Map.get(state, :type_hint)

    args
    |> Enum.reduce(state, fn operand, acc -> walk_hinted(operand, acc, hint) end)
    |> Map.put(:type_hint, prior)
  end

  defp walk_operands_hinted(arg, hint, state), do: walk_operands_hinted([arg], hint, state)

  # A direct variable operand receives the hint; anything else is descended
  # with NO hint, so the hint never reaches a nested call's arguments.
  defp walk_hinted({name, _meta, ctx} = operand, state, hint)
       when is_atom(name) and is_atom(ctx) do
    walk(operand, Map.put(state, :type_hint, hint))
  end

  defp walk_hinted(operand, state, _hint), do: walk(operand, Map.put(state, :type_hint, nil))

  defp maybe_emit_variable_candidate(state, node, name, meta) do
    cond do
      not Map.get(state, :emit_variables, false) -> state
      not variable_read?(state, name) -> state
      not mutable_target?(state, name) -> state
      true -> emit_variable_candidate(state, node, name, meta)
    end
  end

  # M57 — THE single classifier for "is this `{name, meta, atom}` node a mutable
  # variable READ?" All read-side non-variable exclusions route through here.
  # Taxonomy of identifiers that look like variables but are not mutable reads:
  #
  #   * name-level — `_`-prefixed / reserved nullary macros (`bindable_var?/1`).
  #   * env-level — not a `context: nil` read in a trusted `:function_body`
  #     (patterns/guards/module bodies/opaque-macro descendants).
  #   * bitstring specifier — `<<x::bits>>` -> `bits` (`:in_bitstring` flag, set
  #     while descending `<<>>` segments).
  #   * codegen function — body builds quoted code (`:in_codegen`, M57).
  #   * pipe-rhs / `&`-capture function names (`x |> to_string`, `&f/n`) —
  #     handled STRUCTURALLY in `descend/2`, which never visits those nodes.
  #
  # Binding-side exclusions (which names a PATTERN binds) live in
  # `pattern_vars/1` (pins, bitstring `::` specifiers, `\\` default exprs).
  defp variable_read?(state, name) do
    bindable_var?(name) and state.context == nil and state.scope == :function_body and
      state.trust_level == :trusted and
      not Map.get(state, :in_bitstring, false) and
      not Map.get(state, :in_codegen, false)
  end

  # A read is worth a candidate only when some mutator can act on it: another
  # in-scope variable to swap to (VariableReplace, M54) OR a type hint
  # (VariableToLiteral, M56).
  defp mutable_target?(state, name) do
    MapSet.size(MapSet.delete(current_bound_vars(state), name)) > 0 or
      Map.get(state, :type_hint) != nil
  end

  defp emit_variable_candidate(state, node, name, meta) do
    alternatives = current_bound_vars(state) |> MapSet.delete(name) |> Enum.sort()

    case variable_span(state, name, meta) do
      nil ->
        state

      span ->
        candidate =
          build_variable_candidate(
            state,
            node,
            meta,
            span,
            alternatives,
            Map.get(state, :type_hint)
          )

        %{state | candidates: [{candidate, state_snapshot(state)} | state.candidates]}
    end
  end

  defp build_variable_candidate(state, node, meta, span, alternatives, type_hint) do
    %AstCandidate{
      file: state.file,
      line: Keyword.get(meta, :line),
      column: Keyword.get(meta, :column),
      syntactic_name: :__variable__,
      syntactic_arity: 0,
      source_span: span,
      env_context: nil,
      enclosing_module: state.module,
      ast_path: state.ast_path,
      ast_path_hash: path_hash(state.ast_path),
      node: node,
      bound_vars: alternatives,
      type_hint: type_hint
    }
  end

  defp variable_span(state, name, meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    with true <- is_integer(line) and is_integer(column),
         start_byte when is_integer(start_byte) <- byte_offset(state, line, column) do
      end_byte = start_byte + byte_size(Atom.to_string(name))
      {end_line, end_column} = byte_to_line_col(state.line_offsets, end_byte)

      %SourceSpan{
        file: state.file,
        start_line: line,
        start_column: column,
        end_line: end_line,
        end_column: end_column,
        start_byte: start_byte,
        end_byte: end_byte
      }
    else
      _ -> nil
    end
  end

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

  # M50: bare map / n-tuple literals are unwrapped AST nodes (the
  # literal_encoder does not wrap them). Emit a CollectionEmpty candidate
  # (when body-eligible), then descend exactly as `classify_user_call`
  # would for that scope — so existing inner candidates are unchanged.
  defp classify_call(:%{}, meta, pairs, state) do
    state
    |> maybe_emit_map_candidate(meta, pairs)
    |> then(&classify_user_call(:%{}, meta, pairs, &1))
  end

  defp classify_call(:{}, meta, elems, state) do
    state
    |> maybe_emit_ntuple_candidate(meta, elems)
    |> then(&classify_user_call(:{}, meta, elems, &1))
  end

  # M53: descend bitstring segments with an `in_bitstring` flag set so
  # `match_literal_candidate?/2` skips segment-size literals (`<<x::16>>`),
  # where a pattern-position literal swap can produce an invalid match. The
  # flag clears on return (we thread `snapshots`/`candidates` back onto the
  # original, flag-free state). Body-position bitstring literals are
  # unaffected (the flag only gates the `:match` branch).
  defp classify_call(:<<>>, _meta, segments, state) when is_list(segments) do
    inner = descend_args(segments, Map.put(state, :in_bitstring, true))
    %{state | snapshots: inner.snapshots, candidates: inner.candidates}
  end

  # M56: type-determining operators. Walk operands with a one-shot type hint
  # so a direct variable operand (`a + 1`, `s <> x`, `xs ++ ys`) is offered to
  # VariableToLiteral. The hint is SHALLOW: it applies only to a direct
  # variable operand, never through a nested call (`f(x) + 1` does NOT hint
  # `x`). Traversal is otherwise identical to `descend_args/2`, so existing
  # candidate discovery (literals, inner variables) is unchanged.
  defp classify_call(op, _meta, args, state) when op in @number_hint_ops,
    do: walk_operands_hinted(args, :number, state)

  defp classify_call(op, _meta, args, state) when op in @binary_hint_ops,
    do: walk_operands_hinted(args, :binary, state)

  defp classify_call(op, _meta, args, state) when op in @list_hint_ops,
    do: walk_operands_hinted(args, :list, state)

  defp classify_call(op, _meta, args, state) when op in @boolean_hint_ops,
    do: walk_operands_hinted(args, :boolean, state)

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

  # `%{...} → %{}`: skip empty maps and map-update (`%{m | …}`) forms.
  defp maybe_emit_map_candidate(state, meta, pairs) do
    cond do
      :collection not in state.literal_kinds -> state
      pairs == [] -> state
      map_update?(pairs) -> state
      not body_eligible?(state) -> state
      true -> add_collection_candidate(state, {:%{}, meta, pairs}, meta, :__map_literal__)
    end
  end

  # `{a, b, c} → {}`: only arity >= 3 (2-tuples ship via the wrapped path).
  defp maybe_emit_ntuple_candidate(state, meta, elems) do
    cond do
      :collection not in state.literal_kinds -> state
      length(elems) < 3 -> state
      not body_eligible?(state) -> state
      true -> add_collection_candidate(state, {:{}, meta, elems}, meta, :__ntuple_literal__)
    end
  end

  defp map_update?([{:|, _meta, _args} | _rest]), do: true
  defp map_update?(_pairs), do: false

  defp add_collection_candidate(state, node, meta, syntactic_name) do
    candidate = build_collection_candidate(state, node, meta, syntactic_name)
    %{state | candidates: [{candidate, state_snapshot(state)} | state.candidates]}
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
