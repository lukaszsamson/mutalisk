defmodule Mut.SchemaPlacerTest do
  use ExUnit.Case, async: true

  alias Mut.Mutant
  alias Mut.SchemaPlacer

  test "empty mutant list returns input AST unchanged" do
    ast = parsed!("defmodule Sample do\n  def f, do: 1 + 2\nend")

    assert SchemaPlacer.place(ast, []) == ast
  end

  test "inline schema uses persistent_term call and generated case metadata" do
    source = "defmodule Sample do\n  def f(a), do: a + 1\nend"
    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 14], [{:a, [line: 2, column: 13], nil}, 1]}
      )

    instrumented = SchemaPlacer.place(ast, [mutant])
    [case_ast] = schema_cases(instrumented)

    assert {:case, meta, [scrutinee, [do: arms]]} = case_ast

    assert Keyword.take(meta, [:mut_schema?, :mut_ids, :generated, :line]) == [
             mut_schema?: true,
             mut_ids: [11],
             generated: true,
             line: 2
           ]

    assert persistent_term_get?(scrutinee)
    assert arm_patterns(arms) == [0, 11, :_]
  end

  test "hoisted schema prepends one binding and all cases use the same variable" do
    source = "defmodule Sample do\n  def f(a), do: (a + 1) * (a - 1)\nend"
    ast = parsed!(source)

    mutants = [
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 15], [{:a, [line: 2, column: 14], nil}, 1]}
      ),
      mutant(
        ast,
        source,
        :-,
        12,
        7,
        {:+, [line: 2, column: 25], [{:a, [line: 2, column: 24], nil}, 1]}
      )
    ]

    instrumented = SchemaPlacer.place(ast, mutants)
    body = function_body(instrumented, :f)
    assert {:__block__, [], [{:=, [generated: true], [hoisted_var, hoist_call]}, _expr]} = body
    assert {:mutalisk_schema_active, meta, Mut.SchemaPlacer} = hoisted_var
    assert Keyword.has_key?(meta, :counter)
    assert persistent_term_get?(hoist_call)

    assert Enum.map(schema_cases(instrumented), fn {:case, _meta, [scrutinee, _arms]} ->
             scrutinee
           end) == [hoisted_var, hoisted_var]
  end

  test "multiple mutants sharing a source position produce one case with both arms" do
    source = "defmodule Sample do\n  def f(a), do: a + 1\nend"
    ast = parsed!(source)
    hash = path_hash_for(ast, source, :+)

    mutants = [
      mutant(hash, 11, {:-, [line: 2, column: 14], [{:a, [line: 2, column: 13], nil}, 1]}),
      mutant(hash, 12, {:*, [line: 2, column: 14], [{:a, [line: 2, column: 13], nil}, 1]})
    ]

    [case_ast] = SchemaPlacer.place(ast, mutants) |> schema_cases()
    assert {:case, meta, [_scrutinee, [do: arms]]} = case_ast
    assert Keyword.fetch!(meta, :mut_ids) == [11, 12]
    assert arm_patterns(arms) == [0, 11, 12, :_]
  end

  test "guard context is refused when a matching mutant slips through" do
    source = "defmodule Sample do\n  def f(a) when a > 0, do: a\nend"
    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :>,
        11,
        7,
        {:<=, [line: 2, column: 17], [{:a, [line: 2, column: 15], nil}, 0]}
      )

    assert_raise SchemaPlacer.RefusedContext, ~r/inside a when clause guard/, fn ->
      SchemaPlacer.place(ast, [mutant])
    end
  end

  test "instrument_file returns rendered source and placement map keyed by formatted case locations" do
    source = "defmodule Sample do\n  def f(a), do: a + 1\nend\n"
    path = Path.expand("tmp/schema_placer_sample.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 14], [{:a, [line: 2, column: 13], nil}, 1]}
      )

    assert {:ok, rendered, %SchemaPlacer.PlacementMap{} = placement_map, []} =
             SchemaPlacer.instrument_file(path, [%{mutant | file: "tmp/schema_placer_sample.ex"}])

    assert String.contains?(rendered, "case :persistent_term.get")
    assert placement_map.file == "tmp/schema_placer_sample.ex"
    assert Enum.map(placement_map.entries, & &1.mut_ids) == [[11]]
    assert [%{start_line: start_line, end_line: end_line} | _rest] = placement_map.entries
    assert start_line <= end_line
  end

  test "rendered hoist variable does not collide with a user mut_active binding" do
    source =
      "defmodule Sample do\n  def f(a), do: (mut_active = a + 1; mut_active * (a - 1))\nend"

    ast = parsed!(source)

    mutants = [
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 31], [{:a, [line: 2, column: 30], nil}, 1]}
      ),
      mutant(
        ast,
        source,
        :-,
        12,
        7,
        {:+, [line: 2, column: 51], [{:a, [line: 2, column: 50], nil}, 1]}
      )
    ]

    rendered = ast |> SchemaPlacer.place(mutants) |> SchemaPlacer.render()
    module = Module.concat([:"SchemaCollisionTest_#{:erlang.unique_integer([:positive])}"])
    rendered = String.replace(rendered, "defmodule Sample do", "defmodule #{module} do")
    Code.compile_string(rendered, "schema_collision_test.ex")
    on_exit(fn -> Mut.Runtime.clear() end)

    Mut.Runtime.set_active(0)
    assert module.f(3) == 8
    assert String.contains?(rendered, "mutalisk_schema_active")
    assert String.contains?(rendered, "mut_active =")
  end

  test "macro body context is refused when a matching mutant slips through" do
    source = "defmodule Sample do\n  defmacro f(a), do: a + 1\nend"
    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 25], [{:a, [line: 2, column: 24], nil}, 1]}
      )

    assert_raise SchemaPlacer.RefusedContext, ~r/inside a defmacro\/defmacrop body/, fn ->
      SchemaPlacer.place(ast, [mutant])
    end
  end

  test "place_with_refusals returns refused mutant instead of raising" do
    source = "defmodule Sample do\n  defmacro f(a), do: a + 1\nend"
    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :+,
        11,
        7,
        {:-, [line: 2, column: 25], [{:a, [line: 2, column: 24], nil}, 1]}
      )

    assert {placed, [%{mutant: refused_mutant, reason: reason}]} =
             SchemaPlacer.place_with_refusals(ast, [mutant])

    # AST is returned unchanged (no schema case wrapping the refused site)
    assert schema_cases(placed) == []
    assert refused_mutant.id == 11
    assert reason =~ "defmacro/defmacrop body"
  end

  test "place_with_refusals partitions accepted from refused mutants by candidate hash" do
    source = """
    defmodule Sample do
      def ok(a), do: a + 1
      defmacro bad(a), do: a * 1
    end
    """

    ast = parsed!(source)

    accepted =
      mutant(ast, source, :+, 21, 2, {:-, [line: 2, column: 18], [{:a, [], nil}, 1]})

    refused =
      mutant(ast, source, :*, 22, 3, {:/, [line: 3, column: 27], [{:a, [], nil}, 1]})

    {placed, refusals} =
      SchemaPlacer.place_with_refusals(ast, [accepted, refused])

    # Exactly one schema case rendered (for the accepted mutant in def body).
    assert length(schema_cases(placed)) == 1
    assert [%{mutant: %{id: 22}, reason: reason}] = refusals
    assert reason =~ "defmacro/defmacrop body"
  end

  defp parsed!(source) do
    {:ok, ast} = Mut.SourceParse.parse_string(source, "lib/sample.ex")
    ast
  end

  defp mutant(ast, source, op, id, line, mutated_ast) do
    hash = path_hash_for(ast, source, op)
    mutant(hash, id, mutated_ast, line)
  end

  defp mutant(hash, id, mutated_ast, line \\ 2) do
    %Mutant{
      id: id,
      stable_id: "stable-#{id}",
      engine: :schema,
      mutator: Mut.Mutator.Arithmetic,
      mutator_name: "Arithmetic",
      mutation_kind: :arithmetic_op,
      original_dispatch: "Kernel.+/2",
      ast_path_hash: hash,
      file: "lib/sample.ex",
      line: line,
      original_ast: {:+, [line: line], [1, 2]},
      mutated_ast: mutated_ast,
      description: "test mutant"
    }
  end

  defp path_hash_for(ast, source, op) do
    ast
    |> Mut.AstWalk.dispatch_candidates(file: "lib/sample.ex", source: source)
    |> Enum.find(&(&1.syntactic_name == op))
    |> Map.fetch!(:ast_path_hash)
  end

  defp schema_cases(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.filter(fn
      {:case, meta, _args} when is_list(meta) -> Keyword.get(meta, :mut_schema?, false)
      _other -> false
    end)
  end

  defp function_body(ast, name) do
    ast
    |> Macro.prewalker()
    |> Enum.find_value(fn
      {:def, _meta, [{^name, _head_meta, _args}, [do: body]]} -> body
      _other -> nil
    end)
  end

  defp persistent_term_get?(
         {{:., _, [:persistent_term, :get]}, _,
          [{{:., _, [{:__aliases__, _, [:Mut, :Runtime]}, :active_key]}, _, []}, 0]}
       ),
       do: true

  defp persistent_term_get?(_ast), do: false

  defp arm_patterns(arms) do
    Enum.map(arms, fn
      {:->, _meta, [[{:_, _wild_meta, nil}], _body]} -> :_
      {:->, _meta, [[value], _body]} -> value
    end)
  end
end
