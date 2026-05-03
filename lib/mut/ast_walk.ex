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

  defp acc(file, source, line_offsets, span_fallback?) do
    %{
      frames: [],
      candidates: [],
      file: file,
      source: source,
      line_offsets: line_offsets,
      span_fallback?: span_fallback?
    }
  end

  defp pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_candidate(node, path, acc, nil)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp post(node, acc) do
    {node, pop_frame(node, acc)}
  end

  defp attribute_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_attribute_candidate(node, path, acc)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp guard_pre(node, acc) do
    {path, acc} = enter_path(node, acc)
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
        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: Keyword.get(meta, :column),
          syntactic_name: name,
          syntactic_arity: arity,
          source_span:
            Compute.from_meta(meta, acc.source, acc.file, acc.line_offsets) ||
              fallback_source_text_span(node, meta, acc),
          env_context: env_context,
          ast_path: path,
          ast_path_hash: path_hash(path),
          node: node
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
