defmodule Mut.SchemaPlacer do
  @moduledoc "Places runtime-selectable mutation schemata into source ASTs."

  alias Mut.Mutant

  @function_defs ~w(def defp)a
  @macro_defs ~w(defmacro defmacrop)a
  @definition_defs @function_defs ++ @macro_defs
  @no_descend ~w(quote unquote unquote_splicing)a
  @clause_heads ~w(case with fn for)a

  defmodule PlacementMap do
    @moduledoc "Maps rendered schema locations to mutant IDs for rollback."

    @enforce_keys [:file, :entries]
    defstruct [:file, :entries]

    @type location :: {line :: pos_integer(), column :: pos_integer() | nil}
    @type t :: %__MODULE__{file: Path.t(), entries: %{location => [non_neg_integer()]}}
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

  @spec place(Macro.t(), [Mutant.t()]) :: Macro.t()
  def place(ast, []), do: ast

  def place(ast, mutants) when is_list(mutants) do
    groups = mutant_groups(mutants)
    hoist_plan = hoist_plan(ast, groups)
    {instrumented, _acc} = Macro.traverse(ast, acc(groups, hoist_plan), &pre/2, &post/2)
    instrumented
  end

  @spec render(Macro.t()) :: String.t()
  def render(ast) do
    ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @spec instrument_file(file :: Path.t(), [Mutant.t()]) ::
          {:ok, instrumented_source :: String.t(), PlacementMap.t()} | {:error, term}
  def instrument_file(file, mutants) do
    with {:ok, {ast, _source}} <- Mut.SourceParse.parse(file) do
      file_mutants = Enum.filter(mutants, &same_file?(&1.file, file))
      rendered = render(place(ast, file_mutants))
      {:ok, rendered, placement_map(file, rendered)}
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
    %{frames: [], groups: groups, hoist_plan: hoist_plan, def_stack: [], skip_depth: 0}
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

    node =
      cond do
        group && acc.skip_depth > 0 ->
          raise_refused(group, "inside quote/unquote/unquote_splicing")

        group ->
          refused = refused_context(path)

          if refused do
            raise_refused(group, refused)
          else
            schema_case(node, group, scrutinee(acc))
          end

        true ->
          node
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
      clause_head_pattern_path?(path) -> "inside a case/with/fn/for clause head pattern"
      true -> nil
    end
  end

  defp raise_refused([mutant | _rest], description) do
    raise RefusedContext,
      mutant_id: mutant.id,
      file: mutant.file,
      line: mutant.line,
      description: description
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

  defp clause_head_pattern_path?(path) do
    path
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn
      [{:elem, clause_parent, _}, {:elem, :->, 0}, {:elem, :do_block, _}]
      when clause_parent in @clause_heads ->
        true

      _other ->
        false
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
    |> Enum.reduce(%{}, fn
      {:case, meta, [scrutinee, [do: arms]]}, entries when is_list(meta) ->
        ids = schema_arm_ids(arms)

        if ids == [] or not schema_scrutinee?(scrutinee) do
          entries
        else
          Map.put(entries, {Keyword.get(meta, :line), Keyword.get(meta, :column)}, ids)
        end

      _other, entries ->
        entries
    end)
  end

  defp schema_arm_ids(arms) do
    ids =
      Enum.flat_map(arms, fn
        {:->, _meta, [[id], _body]} when is_integer(id) and id > 0 -> [id]
        _arm -> []
      end)

    if original_and_wildcard_arms?(arms), do: Enum.sort(ids), else: []
  end

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
