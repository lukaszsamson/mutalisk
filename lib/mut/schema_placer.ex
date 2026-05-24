defmodule Mut.SchemaPlacer do
  @moduledoc "Places runtime-selectable mutation schemata into source ASTs."

  alias Mut.Mutant

  @function_defs ~w(def defp)a
  @macro_defs ~w(defmacro defmacrop)a
  @definition_defs @function_defs ++ @macro_defs
  @no_descend ~w(quote unquote unquote_splicing)a

  defmodule PlacementMap do
    @moduledoc "Maps rendered schema locations to mutant IDs for rollback."

    @enforce_keys [:file, :entries]
    defstruct [:file, :entries]

    @type entry :: %{
            start_line: pos_integer(),
            end_line: pos_integer(),
            column: pos_integer() | nil,
            mut_ids: [non_neg_integer()]
          }
    @type t :: %__MODULE__{file: Path.t(), entries: [entry]}
  end

  defmodule RefusedContext do
    @moduledoc "Raised when a schema mutant is placed in a refused AST context."

    defexception [:mutant_id, :file, :line, :description]

    @type t :: %__MODULE__{
            mutant_id: non_neg_integer(),
            file: Path.t(),
            line: pos_integer() | nil,
            description: String.t()
          }

    @impl true
    def message(exception) do
      "refused schema mutant #{exception.mutant_id} at #{exception.file}:#{exception.line}: " <>
        exception.description
    end
  end

  @typedoc "Refused-context refusal returned by `place_with_refusals/2`."
  @type refusal :: %{mutant: Mutant.t(), reason: String.t()}

  @doc """
  Place schema instrumentation around the given mutants.

  Raises `RefusedContext` if any mutant lands in a refused AST context (macro
  body, when guard, function head pattern, etc.). For a non-raising variant,
  use `place_with_refusals/2`.
  """
  @spec place(Macro.t(), [Mutant.t()]) :: Macro.t()
  def place(ast, []), do: ast

  def place(ast, mutants) when is_list(mutants) do
    case place_with_refusals(ast, mutants) do
      {instrumented, []} ->
        instrumented

      {_instrumented, [%{mutant: mutant, reason: reason} | _rest]} ->
        raise RefusedContext,
          mutant_id: mutant.id,
          file: mutant.file,
          line: mutant.line,
          description: reason
    end
  end

  @doc """
  Like `place/2`, but instead of raising on refused contexts, returns the
  partially-instrumented AST and a list of refusals. Refused mutants are not
  wrapped in schema cases; the caller is expected to reroute them to the
  fallback engine (or mark them invalid).
  """
  @spec place_with_refusals(Macro.t(), [Mutant.t()]) :: {Macro.t(), [refusal()]}
  def place_with_refusals(ast, []), do: {ast, []}

  def place_with_refusals(ast, mutants) when is_list(mutants) do
    groups = mutant_groups(mutants)
    hoist_plan = hoist_plan(ast, groups)
    initial_acc = acc(groups, hoist_plan)
    {instrumented, %{refusals: refusals}} = Macro.traverse(ast, initial_acc, &pre/2, &post/2)
    {instrumented, Enum.reverse(refusals)}
  end

  @spec render(Macro.t()) :: String.t()
  def render(ast) do
    ast
    |> strip_heredoc_delimiters()
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  # `Macro.to_string/1` honors `:delimiter` token metadata when re-emitting
  # string and bitstring nodes. For heredoc-delimited interpolated strings
  # (`"\"\"\""` or `"'''"`) whose source uses a `\` line-continuation before
  # the closing delimiter (gettext lib/gettext/extractor_agent.ex:83 and
  # lib/gettext/plural.ex:79 are real-world cases), the round-trip drops
  # the continuation and emits the closing `"""` on the same line as the
  # last interpolation -- e.g.
  #
  #     Logger.warning("""
  #     foo: #{x}""")
  #
  # which neither `Code.string_to_quoted/1` nor `Code.format_string!/1`
  # can parse (TokenMissingError: missing terminator """).
  #
  # We strip the heredoc delimiter metadata on interpolated-string AST
  # nodes (`:<<>>`) so `Macro.to_string/1` falls back to regular `"..."`
  # form, which round-trips cleanly.
  #
  # **Critically scoped to `:<<>>` only — NOT to sigil nodes (`:sigil_S`,
  # `:sigil_s`, ...).** M34 finding (2026-05-10): stripping a sigil's
  # heredoc delimiter forces Macro.to_string into the regular `~S"..."`
  # form, which fails to parse when the sigil body contains literal `"`
  # characters (because `"` would close the sigil). phoenix_html v4.3.0
  # `lib/phoenix_html.ex` `@doc ~S"""...""" ` blocks contain `iex>`
  # examples with embedded escaped quotes; pre-M34 stripping crashed
  # schema build on these targets. The fix narrows the strip to
  # interpolated-string nodes only — sigil heredocs render correctly via
  # Macro.to_string's native sigil-heredoc emission, no workaround needed.
  defp strip_heredoc_delimiters(ast) do
    Macro.prewalk(ast, fn
      {:<<>>, meta, args} when is_list(meta) ->
        case Keyword.get(meta, :delimiter) do
          d when d in ["\"\"\"", "'''"] ->
            new_meta = meta |> Keyword.delete(:delimiter) |> Keyword.delete(:indentation)
            {:<<>>, new_meta, args}

          _other ->
            {:<<>>, meta, args}
        end

      other ->
        other
    end)
  end

  @spec instrument_file(file :: Path.t(), [Mutant.t()]) ::
          {:ok, instrumented_source :: String.t(), PlacementMap.t(), [refusal()]}
          | {:error, term}
  def instrument_file(file, mutants) do
    with {:ok, {ast, _source}} <- Mut.SourceParse.parse(file) do
      file_mutants = Enum.filter(mutants, &same_file?(&1.file, file))
      {placed_ast, refusals} = place_with_refusals(ast, file_mutants)
      rendered = render(placed_ast)
      {:ok, rendered, placement_map(file, rendered), refusals}
    end
  end

  defp mutant_groups(mutants) do
    mutants
    |> Enum.group_by(& &1.ast_path_hash)
    |> Map.new(fn {hash, group} -> {hash, Enum.sort_by(group, & &1.id)} end)
  end

  defp hoist_plan(ast, groups) do
    {_ast, acc} =
      Macro.traverse(ast, %{frames: [], bodies: %{}, groups: groups}, &hoist_pre/2, &hoist_post/2)

    Map.new(acc.bodies, fn {path, hashes} ->
      mode =
        if MapSet.size(hashes) >= 2,
          do: {:hoisted, Macro.unique_var(:mutalisk_schema_active, __MODULE__)},
          else: :inline

      {path, mode}
    end)
  end

  defp acc(groups, hoist_plan) do
    %{
      frames: [],
      groups: groups,
      hoist_plan: hoist_plan,
      def_stack: [],
      skip_depth: 0,
      refusals: []
    }
  end

  defp pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_push_def(node, path, acc)
    acc = maybe_push_skip(node, acc)
    {node, push_frame(node, path, acc)}
  end

  defp post(node, acc) do
    path = hd(acc.frames).path
    group = Map.get(acc.groups, path_hash(path))

    {node, acc} =
      cond do
        group && acc.skip_depth > 0 ->
          {node, record_refused(acc, group, "inside quote/unquote/unquote_splicing")}

        group ->
          case refused_context(path) do
            nil -> {schema_case(node, group, scrutinee(acc)), acc}
            description -> {node, record_refused(acc, group, description)}
          end

        true ->
          {node, acc}
      end

    node = maybe_hoist_body(node, path, acc)
    acc = acc |> pop_frame() |> maybe_pop_skip(node) |> maybe_pop_def(path)
    {node, acc}
  end

  defp hoist_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_record_body_group(path, acc)
    {node, push_frame(node, path, acc)}
  end

  defp hoist_post(node, acc), do: {node, pop_frame(acc)}

  defp maybe_record_body_group(path, acc) do
    with [_ | _] <- path,
         hash when is_binary(hash) <- path_hash(path),
         true <- Map.has_key?(acc.groups, hash),
         body_path when not is_nil(body_path) <- enclosing_function_body_path(path) do
      %{
        acc
        | bodies: Map.update(acc.bodies, body_path, MapSet.new([hash]), &MapSet.put(&1, hash))
      }
    else
      _missing -> acc
    end
  end

  defp maybe_push_def({kind, _meta, [_head, [do: _body]]}, path, acc)
       when kind in @function_defs do
    body_path = path ++ [{:elem, kind, 1}, {:elem, :list, 0}, {:elem, :do_block, 1}]
    mode = Map.get(acc.hoist_plan, body_path, :inline)

    %{acc | def_stack: [%{path: path, body_path: body_path, mode: mode} | acc.def_stack]}
  end

  defp maybe_push_def(_node, _path, acc), do: acc

  defp maybe_pop_def(acc, path) do
    case acc.def_stack do
      [%{path: ^path} | rest] -> %{acc | def_stack: rest}
      _other -> acc
    end
  end

  defp maybe_push_skip({name, _meta, _args}, acc) when name in @no_descend,
    do: %{acc | skip_depth: acc.skip_depth + 1}

  defp maybe_push_skip(_node, acc), do: acc

  defp maybe_pop_skip(acc, {name, _meta, _args}) when name in @no_descend,
    do: %{acc | skip_depth: acc.skip_depth - 1}

  defp maybe_pop_skip(acc, _node), do: acc

  defp maybe_hoist_body(node, path, %{
         def_stack: [%{body_path: body_path, mode: {:hoisted, variable}} | _rest]
       }) do
    if path == body_path do
      block_with_hoist(node, variable)
    else
      node
    end
  end

  defp maybe_hoist_body(node, _path, _acc), do: node

  defp block_with_hoist({:__block__, meta, statements}, variable) do
    {:__block__, meta, [hoist_binding(variable) | statements]}
  end

  defp block_with_hoist(expr, variable), do: {:__block__, [], [hoist_binding(variable), expr]}

  defp hoist_binding(variable), do: {:=, [generated: true], [variable, active_get_ast()]}

  defp schema_case(original, mutants, scrutinee) do
    ids = Enum.map(mutants, & &1.id)
    meta = [mut_schema?: true, mut_ids: ids, generated: true, line: original_line(original)]
    arms = [{:->, [generated: true], [[0], original]}]
    arms = arms ++ Enum.map(mutants, &{:->, [generated: true], [[&1.id], &1.mutated_ast]})
    arms = arms ++ [{:->, [generated: true], [[{:_, [generated: true], nil}], original]}]
    {:case, meta, [scrutinee, [do: arms]]}
  end

  defp scrutinee(%{def_stack: [%{mode: {:hoisted, variable}} | _rest]}), do: variable
  defp scrutinee(_acc), do: active_get_ast()

  defp active_get_ast do
    {{:., [generated: true], [:persistent_term, :get]}, [generated: true],
     [
       {{:., [generated: true],
         [{:__aliases__, [generated: true], [:Mut, :Runtime]}, :active_key]}, [generated: true],
        []},
       0
     ]}
  end

  defp refused_context(path) do
    cond do
      Enum.any?(path, &match?({:elem, :when, 1}, &1)) -> "inside a when clause guard"
      function_head_path?(path) -> "inside a def/defp/defmacro/defmacrop head pattern"
      macro_body_path?(path) -> "inside a defmacro/defmacrop body"
      Enum.any?(path, &match?({:elem, :@, _index}, &1)) -> "inside a module attribute value"
      lhs_match_path?(path) -> "inside the left-hand side of a match"
      bitstring_segment_path?(path) -> "inside a bitstring segment"
      clause_head_pattern_path?(path) -> "inside a clause head pattern"
      true -> nil
    end
  end

  # A literal anywhere inside a `<<...>>` cannot be replaced by a `case` gate:
  # segment size/unit/type specifiers (`<<x::128>>`) must be compile-time
  # constants, and segment values are bound by binary-construction rules.
  defp bitstring_segment_path?(path),
    do: Enum.any?(path, &match?({:elem, :<<>>, _index}, &1))

  defp record_refused(acc, group, description) do
    refusals = Enum.map(group, &%{mutant: &1, reason: description})
    %{acc | refusals: refusals ++ acc.refusals}
  end

  defp function_head_path?(path) do
    function_head_tail?(Enum.take(path, -1)) or function_head_tail?(Enum.take(path, -2))
  end

  defp function_head_tail?([{:elem, parent, 0}]) when parent in @definition_defs, do: true

  defp function_head_tail?([{:elem, parent, 0}, {:elem, :when, 0}])
       when parent in @definition_defs,
       do: true

  defp function_head_tail?(_tail), do: false

  defp macro_body_path?(path),
    do: Enum.any?(path, &match?({:elem, kind, 1} when kind in @macro_defs, &1))

  defp lhs_match_path?(path), do: Enum.any?(path, &match?({:elem, :=, 0}, &1))

  # The head position of a clause arrow (`pattern -> body`) and of a
  # `with`/`for` generator (`pattern <- enum`) is a match pattern, where a
  # `case` gate is not allowed. Index 0 of `:->`/`:<-` is the head; index 1+
  # is the body/enumerable, which stays placeable. We deliberately over-refuse
  # `cond` arrow heads (boolean expressions, not patterns) -- they simply route
  # to the fallback engine, which is always safe.
  defp clause_head_pattern_path?(path) do
    Enum.any?(path, fn
      {:elem, :->, 0} -> true
      {:elem, :<-, 0} -> true
      _other -> false
    end)
  end

  defp enclosing_function_body_path(path) do
    path
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{:elem, kind, 1}, index} when kind in @function_defs -> Enum.take(path, index + 3)
      _other -> nil
    end)
  end

  defp enter_path(_node, %{frames: []} = acc), do: {[], acc}

  defp enter_path(_node, %{frames: [parent | rest]} = acc) do
    path = parent.path ++ [{:elem, parent.kind, parent.next_index}]
    {path, %{acc | frames: [%{parent | next_index: parent.next_index + 1} | rest]}}
  end

  defp push_frame(node, path, acc) do
    %{acc | frames: [%{kind: node_kind(node), path: path, next_index: 0} | acc.frames]}
  end

  defp pop_frame(%{frames: [_frame | rest]} = acc), do: %{acc | frames: rest}

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

  defp original_line({_name, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp original_line(_node), do: nil

  defp placement_map(file, rendered) do
    entries =
      case Mut.SourceParse.parse_string(rendered, file) do
        {:ok, ast} -> schema_entries(ast)
        {:error, _reason} -> %{}
      end

    %PlacementMap{file: relativize(file), entries: entries}
  end

  defp schema_entries(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.reduce([], fn
      # Schema-injected cases always have a literal list of arms. Target
      # source can also contain `case x do unquote(arms) end` (in macro
      # bodies) where the arms slot is an `{:unquote, _, _}` AST node,
      # not a list -- guard with `is_list(arms)` so we never feed those
      # to `schema_arm_ids/1`.
      {:case, meta, [scrutinee, [do: arms]]}, entries
      when is_list(meta) and is_list(arms) ->
        ids = schema_arm_ids(arms)

        if ids == [] or not schema_scrutinee?(scrutinee) do
          entries
        else
          schema_arm_entries(arms) ++ entries
        end

      _other, entries ->
        entries
    end)
    |> Enum.reverse()
  end

  defp schema_arm_ids(arms) when is_list(arms) do
    ids =
      Enum.flat_map(arms, fn
        {:->, _meta, [[id], _body]} when is_integer(id) and id > 0 -> [id]
        _arm -> []
      end)

    if original_and_wildcard_arms?(arms), do: Enum.sort(ids), else: []
  end

  defp schema_arm_ids(_arms), do: []

  defp schema_arm_entries(arms) when is_list(arms) do
    Enum.flat_map(arms, fn
      {:->, _meta, [[id], body]} when is_integer(id) and id > 0 ->
        {start_line, end_line, column} = line_range(body)
        [%{start_line: start_line, end_line: end_line, column: column, mut_ids: [id]}]

      _arm ->
        []
    end)
  end

  defp schema_arm_entries(_arms), do: []

  defp line_range({_name, meta, _args}) when is_list(meta) do
    start_line = Keyword.fetch!(meta, :line)
    end_line = meta |> Keyword.get(:end_of_expression, []) |> Keyword.get(:line, start_line)
    {start_line, end_line, Keyword.get(meta, :column)}
  end

  defp line_range(_node), do: {1, 1, nil}

  defp original_and_wildcard_arms?([{:->, _meta, [[0], _body]} | rest]) do
    match?({:->, _meta, [[{:_, _wild_meta, nil}], _body]}, List.last(rest))
  end

  defp original_and_wildcard_arms?(_arms), do: false

  defp schema_scrutinee?({:mutalisk_schema_active, _meta, nil}), do: true

  defp schema_scrutinee?(
         {{:., _, [:persistent_term, :get]}, _,
          [{{:., _, [{:__aliases__, _, [:Mut, :Runtime]}, :active_key]}, _, []}, 0]}
       ),
       do: true

  defp schema_scrutinee?(_scrutinee), do: false

  defp same_file?(mutant_file, file) do
    relative = relativize(file)
    mutant_file == relative or String.ends_with?(Path.expand(file), "/" <> mutant_file)
  end

  defp relativize(file) do
    cwd = File.cwd!()
    file |> Path.expand() |> Path.relative_to(cwd)
  end
end
