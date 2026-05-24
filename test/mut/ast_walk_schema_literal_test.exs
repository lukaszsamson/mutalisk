defmodule Mut.AstWalkSchemaLiteralTest do
  use ExUnit.Case, async: true

  @moduledoc """
  M52 foundation: `schema_literal_candidates/1` assigns scalar literals
  plain-AST positional paths so `Mut.SchemaPlacer` can case-gate them
  with no SchemaPlacer changes and no dispatch-path churn.
  """

  alias Mut.AstWalk
  alias Mut.Mutant
  alias Mut.SchemaPlacer

  defp lits(src), do: AstWalk.schema_literal_candidates(file: "f.ex", source: src)

  test "discovers body-context scalar literals of every kind" do
    src = """
    defmodule F do
      def i, do: 42
      def b, do: true
      def s, do: "hi"
      def f, do: 3.5
      def a, do: :ok
      def n, do: nil
    end
    """

    names = lits(src) |> Enum.map(& &1.syntactic_name) |> Enum.sort()

    assert names == [
             :atom_literal,
             :boolean_literal,
             :float_literal,
             :integer_literal,
             :nil_literal,
             :string_literal
           ]
  end

  test "excludes attribute, function-head pattern, and guard positions" do
    src = """
    defmodule F do
      @attr 7
      def head(99), do: run()
      def guard(x) when x > 88, do: run()
    end
    """

    # 7 (attribute value), 99 (head pattern), 88 (guard) are all refused
    # body positions; the bodies hold no literals. Collections / their
    # elements are covered by the discovery test (elements ARE body scalars).
    assert lits(src) == []
  end

  test "discovered literals place via SchemaPlacer over the plain AST (no refusals)" do
    src = "defmodule F do\n  def greet, do: \"hi\"\n  def calc(a), do: a + 42\nend\n"
    cands = lits(src)
    assert length(cands) == 2

    {:ok, plain} = Code.string_to_quoted(src, columns: true, token_metadata: true)

    mutants =
      cands
      |> Enum.with_index(1)
      |> Enum.map(fn {c, i} ->
        %Mutant{
          id: i,
          stable_id: "s#{i}",
          engine: :schema,
          mutator: nil,
          mutator_name: "Lit",
          mutation_kind: :lit,
          ast_path_hash: c.ast_path_hash,
          file: "f.ex",
          line: c.line,
          column: c.column,
          original_ast: c.node,
          mutated_ast: {:__block__, [], [:MUT]},
          description: "x",
          status: :pending
        }
      end)

    {instrumented, refusals} = SchemaPlacer.place_with_refusals(plain, mutants)
    rendered = SchemaPlacer.render(instrumented)

    assert refusals == []
    # one case-gate per literal
    assert length(Regex.scan(~r/-> :MUT/, rendered)) == 2
    assert rendered =~ ~r/0 ->\s*"hi"/
    assert rendered =~ ~r/0 ->\s*42/
  end

  test "literal paths coexist with dispatch placement in one pass (no dispatch churn)" do
    src = "defmodule F do\n  def calc(a), do: a * 10\nend\n"
    {:ok, plain} = Code.string_to_quoted(src, columns: true, token_metadata: true)

    [disp] = AstWalk.dispatch_candidates(plain, file: "f.ex", source: src)
    [lit] = lits(src)
    refute disp.ast_path_hash == lit.ast_path_hash

    mutants =
      for {c, i} <- Enum.with_index([disp, lit], 1) do
        %Mutant{
          id: i,
          stable_id: "s#{i}",
          engine: :schema,
          mutator: nil,
          mutator_name: "M",
          mutation_kind: :m,
          ast_path_hash: c.ast_path_hash,
          file: "f.ex",
          line: c.line,
          column: c.column,
          original_ast: c.node,
          mutated_ast: {:__block__, [], [:MUT]},
          description: "x",
          status: :pending
        }
      end

    {instrumented, refusals} = SchemaPlacer.place_with_refusals(plain, mutants)
    rendered = SchemaPlacer.render(instrumented)

    assert refusals == []
    # both the `*` dispatch and the `10` literal are gated
    assert length(Regex.scan(~r/-> :MUT/, rendered)) == 2
  end
end
