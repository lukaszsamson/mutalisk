defmodule Mut.MutatorTestSupport do
  @moduledoc false

  alias Mut.Context
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  import Kernel, except: [node: 1]

  def context(opts \\ []) do
    %Context{
      file: Keyword.get(opts, :file, "lib/a.ex"),
      ast_path: Keyword.get(opts, :ast_path, []),
      ast_path_hash: Keyword.get(opts, :ast_path_hash, "hash"),
      engine: Keyword.get(opts, :engine, :schema),
      env_context: Keyword.get(opts, :env_context),
      oracle_site: Keyword.get(opts, :oracle_site)
    }
  end

  def context_for(op, opts \\ []) do
    context(Keyword.put_new(opts, :oracle_site, site(op, resolved_arity: arity_for(op))))
  end

  def ast_node(op), do: {op, [line: 1, column: 1], [1, 2]}
  def unary_node(op), do: {op, [line: 1, column: 1], [{:x, [], nil}]}

  def replacements(mutator, op) do
    mutator.mutate(ast_node(op), context_for(op))
    |> Enum.map(& &1.metadata.replacement)
  end

  defp arity_for(op) when op in [:not, :!], do: 1
  defp arity_for(_op), do: 2

  def candidate(name, arity \\ 2) do
    %AstCandidate{
      file: "lib/a.ex",
      line: 1,
      column: 1,
      syntactic_name: name,
      syntactic_arity: arity,
      ast_path: [],
      ast_path_hash: "hash",
      node: ast_node(name)
    }
  end

  def site(name, opts \\ []) do
    %DispatchSite{
      file: "lib/a.ex",
      line: 1,
      column: 1,
      dispatch_kind: Keyword.get(opts, :dispatch_kind, :imported_function),
      resolved_module: Keyword.get(opts, :resolved_module, Kernel),
      resolved_name: Keyword.get(opts, :resolved_name, name),
      resolved_arity: Keyword.get(opts, :resolved_arity, 2),
      event_file: "lib/a.ex"
    }
  end
end
