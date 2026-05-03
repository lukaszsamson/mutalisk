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

  @type path_elem :: {:elem, atom(), non_neg_integer()}

  @spec dispatch_candidates(Macro.t(), opts :: keyword) :: [AstCandidate.t()]
  def dispatch_candidates(ast, opts) do
    file = Keyword.fetch!(opts, :file)
    source = Keyword.get(opts, :source)
    line_offsets = if source, do: Compute.line_offsets(source), else: %{}
    acc = %{frames: [], candidates: [], file: file, source: source, line_offsets: line_offsets}

    {_ast, acc} = Macro.traverse(ast, acc, &pre/2, &post/2)

    Enum.reverse(acc.candidates)
  end

  defp pre(node, acc) do
    {path, acc} = enter_path(node, acc)
    acc = maybe_candidate(node, path, acc)

    if no_descend?(node) do
      {prune(node), push_frame(node, path, acc)}
    else
      {node, push_frame(node, path, acc)}
    end
  end

  defp post(node, acc) do
    {node, pop_frame(node, acc)}
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

  defp maybe_candidate(node, path, acc) do
    case dispatch_shape(node) do
      {:ok, name, arity, meta} ->
        if ignored_path?(path),
          do: acc,
          else: add_candidate(acc, node, path, name, syntactic_arity(node, path, arity), meta)

      :skip ->
        acc
    end
  end

  defp add_candidate(acc, node, path, name, arity, meta) do
    case Keyword.fetch(meta, :line) do
      {:ok, line} ->
        candidate = %AstCandidate{
          file: acc.file,
          line: line,
          column: Keyword.get(meta, :column),
          syntactic_name: name,
          syntactic_arity: arity,
          source_span: Compute.from_meta(meta, acc.source, acc.file, acc.line_offsets),
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

  defp function_head_path?(path) do
    function_head_tail?(Enum.take(path, -1)) or function_head_tail?(Enum.take(path, -2))
  end

  defp function_head_tail?([{:elem, parent, 0}])
       when parent in ~w(def defp defmacro defmacrop defguard defguardp)a,
       do: true

  defp function_head_tail?([{:elem, parent, 0}, {:elem, :when, 0}])
       when parent in ~w(def defp defmacro defmacrop defguard defguardp)a,
       do: true

  defp function_head_tail?(_tail), do: false

  defp no_descend?({name, _meta, _args}) when name in @no_descend, do: true
  defp no_descend?(_node), do: false

  defp prune({name, meta, _args}), do: {name, meta, []}

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
