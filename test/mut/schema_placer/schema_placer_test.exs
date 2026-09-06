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
    # The instrumented AST is rendered to source and recompiled, so the hoisted
    # variable must be a plain (context-free) name -- hygiene metadata would be
    # lost by the round-trip.
    assert {:mutalisk_schema_active, _meta, nil} = hoisted_var
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

  test "cond clause head is instrumented (boolean expression, not a pattern)" do
    # Regression: a comparison in a `cond` clause head is a body position. It
    # was wrongly refused as a clause-head pattern, rerouted to fallback, and
    # (lacking a byte span) dropped as `invalid` — hiding survivors. It must be
    # schema-instrumented exactly like an `if` condition.
    source =
      "defmodule Sample do\n  def f(n) do\n    cond do\n      n < 10 -> :a\n      true -> :b\n    end\n  end\nend\n"

    ast = parsed!(source)

    mutant =
      mutant(
        ast,
        source,
        :<,
        11,
        4,
        {:<=, [line: 4, column: 9], [{:n, [line: 4, column: 7], nil}, 10]}
      )

    {instrumented, refusals} = SchemaPlacer.place_with_refusals(ast, [mutant])
    assert refusals == []
    assert [{:case, _meta, _arms}] = schema_cases(instrumented)
  end

  test "case clause head dispatch is still refused (real pattern position)" do
    # Guards against over-correction: only `cond` heads are body positions.
    # A `case` `->` head is a pattern — a mutant there must still be refused.
    source =
      "defmodule Sample do\n  def f(x) do\n    case x do\n      a when a > 0 -> a\n      _ -> 0\n    end\n  end\nend\n"

    ast = parsed!(source)

    # `a > 0` is a guard inside the case clause head; place a comparison mutant
    # on it and confirm it is refused (guards are never schema-instrumented).
    hash = path_hash_for(ast, source, :>)

    refused_mutant =
      mutant(hash, 31, {:>=, [line: 4, column: 16], [{:a, [line: 4, column: 14], nil}, 0]}, 4)

    {instrumented, refusals} = SchemaPlacer.place_with_refusals(ast, [refused_mutant])
    assert schema_cases(instrumented) == []
    assert [_refusal] = refusals
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

  test "scalar-literal schema arm gets the arm's real line (not {1,1}) in the placement map" do
    # M52 body-literal class: the schema arm body is a BARE scalar, which after
    # the placement-map's literal_encoder-free re-parse carries no metadata.
    # The placement entry must still report the arm's real line so
    # CompileRollback can isolate a single failing scalar mutant instead of
    # aborting the whole schema build.
    source = "defmodule Sample do\n  def f do\n    side()\n    42\n  end\nend\n"
    path = Path.expand("tmp/schema_placer_scalar.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    candidate =
      Mut.AstWalk.schema_literal_candidates(file: "tmp/schema_placer_scalar.ex", source: source)
      |> Enum.find(&(&1.syntactic_name == :integer_literal))

    refute is_nil(candidate), "expected a body integer-literal candidate"
    # The literal `42` is on line 4.
    assert candidate.line == 4

    literal_mutant = %Mutant{
      id: 11,
      stable_id: "stable-11",
      engine: :schema,
      mutator: Mut.Mutator.IntegerLiteral,
      mutator_name: "IntegerLiteral",
      mutation_kind: :integer_literal,
      original_dispatch: "@integer",
      ast_path_hash: candidate.ast_path_hash,
      file: "tmp/schema_placer_scalar.ex",
      line: candidate.line,
      original_ast: 42,
      mutated_ast: 0,
      description: "replace integer literal 42 with 0"
    }

    assert {:ok, _rendered, %SchemaPlacer.PlacementMap{entries: entries}, []} =
             SchemaPlacer.instrument_file(path, [literal_mutant])

    assert [%{start_line: start_line, mut_ids: [11]}] = entries
    # The bug collapsed bare-scalar arms to the {1, 1} fallback; the fix
    # reports the arm's real line in the rendered (instrumented) source — the
    # coordinate space CompileRollback matches compile diagnostics against.
    # The def is well below line 1, so the only thing that matters is that the
    # arm no longer pins to line 1.
    assert start_line > 1
  end

  test "instrument_file tolerates target source with case arms inside unquote/macro bodies" do
    # M25 follow-up: gettext (and jason post-deps-fix) crashed mid-instrumentation
    # because the rendered AST contains `case x do unquote(arms) end` shapes where
    # the arms slot is an `{:unquote, _, _}` AST node rather than a list of
    # `:->` clauses. The placement-map walker called `Enum.flat_map(arms, ...)`
    # on the unquote node and triggered `Enumerable.impl_for!/1`. We now guard
    # the arms-shape check with `is_list/1` and bail out cleanly.
    source = """
    defmodule Sample do
      defmacro pick(value) do
        quote do
          case unquote(value) do
            unquote(__MODULE__.arms())
          end
        end
      end

      def arms, do: [{:->, [], [[1], :one]}, {:->, [], [[2], :two]}]
    end
    """

    path = Path.expand("tmp/schema_placer_unquote_arms.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    # Empty mutants -- exercises only the placement_map walk over the
    # rendered AST. With the bug in place, this raises Protocol.UndefinedError
    # from Enumerable.impl_for!/1 on the unquote node.
    assert {:ok, _rendered, %SchemaPlacer.PlacementMap{entries: []}, []} =
             SchemaPlacer.instrument_file(path, [])
  end

  test "render/1 round-trips heredocs with trailing interpolation" do
    # M25 follow-up: gettext lib/gettext/extractor_agent.ex:83 has a heredoc
    # whose content ends with an interpolation immediately before the
    # closing `"""` (the source uses a backslash line-continuation to
    # suppress the trailing newline). `Macro.to_string/1` preserves the
    # heredoc delimiter via `:delimiter` metadata but does NOT preserve
    # the backslash continuation, so it re-emits as
    # `"""\nfoo: #{x}"""` -- with the closing `"""` on the same line as
    # the interpolation, which neither `Code.string_to_quoted/1` nor
    # `Code.format_string!/1` can parse (TokenMissingError: missing
    # terminator """). We strip heredoc delimiter metadata before
    # rendering so the output falls back to regular `"..."` strings.
    source =
      "defmodule Sample do\n" <>
        "  def f(x) do\n" <>
        "    Logger.warning(\"\"\"\n" <>
        "    foo: \#{x}\\\n" <>
        "    \"\"\")\n" <>
        "  end\n" <>
        "end\n"

    path = Path.expand("tmp/schema_placer_heredoc.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, rendered, %SchemaPlacer.PlacementMap{}, []} =
             SchemaPlacer.instrument_file(path, [])

    # Rendered output must be re-parseable.
    assert {:ok, _ast} = Mut.SourceParse.parse_string(rendered, path)
    assert rendered =~ "Logger.warning("
  end

  test "render/1 round-trips ~S sigil heredocs containing literal quote characters" do
    # M34 regression: phoenix_html v4.3.0 lib/phoenix_html.ex has @doc
    # blocks using `~S"""..."""` whose body contains `iex>` examples
    # with literal `\"` escape sequences. Pre-M34, `strip_heredoc_delimiters`
    # stripped the heredoc delimiter from sigil nodes too, forcing
    # Macro.to_string into `~S"..."` form which fails to parse when the
    # body contains literal `"` (the `"` would close the sigil prematurely).
    # M34 narrows the strip to `:<<>>` interpolated-string nodes only,
    # leaving sigil heredocs intact so they round-trip via Macro.to_string's
    # native sigil-heredoc emission.
    source = ~S'''
    defmodule Sample do
      @doc ~S"""
      Examples

          iex> attrs([title: "the title", id: "the id"])
          " title=\"the title\" id=\"the id\""
      """
      def f, do: :ok
    end
    '''

    path = Path.expand("tmp/schema_placer_sigil_heredoc.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, rendered, %SchemaPlacer.PlacementMap{}, []} =
             SchemaPlacer.instrument_file(path, [])

    # Rendered output must be re-parseable.
    assert {:ok, _ast} = Mut.SourceParse.parse_string(rendered, path)
    # And the sigil heredoc form must survive the round-trip.
    assert rendered =~ "~S\"\"\""
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

  describe "hoisted binding name selection (rendered-and-recompiled)" do
    test "does not clobber a user variable of the same name" do
      source = """
      defmodule SchemaPlacerCollision do
        def value(mutalisk_schema_active), do: {mutalisk_schema_active, 1, 2}
      end
      """

      {rendered, [first_id, second_id]} = instrument_literals!("collision", source)

      refute rendered =~ "mutalisk_schema_active = :persistent_term.get"
      assert rendered =~ "mutalisk_schema_active_1 = :persistent_term.get"

      module = compile_module!(rendered)

      assert with_active(0, fn -> module.value(42) end) == {42, 1, 2}
      assert with_active(first_id, fn -> module.value(42) end) == {42, 0, 2}
      assert with_active(second_id, fn -> module.value(42) end) == {42, 1, 0}
    end

    test "avoids a name bound only inside a nested fn" do
      source = """
      defmodule SchemaPlacerNestedFn do
        def value(list) do
          mapped = Enum.map(list, fn mutalisk_schema_active -> mutalisk_schema_active + 1 end)
          {mapped, 1, 2}
        end
      end
      """

      {rendered, [inner_id | _rest]} = instrument_literals!("nested_fn", source)

      refute rendered =~ "mutalisk_schema_active = :persistent_term.get"
      assert rendered =~ "mutalisk_schema_active_1 = :persistent_term.get"

      module = compile_module!(rendered)

      assert with_active(0, fn -> module.value([1, 2]) end) == {[2, 3], 1, 2}
      assert with_active(inner_id, fn -> module.value([1, 2]) end) == {[1, 2], 1, 2}
    end

    test "keeps the base name when the function has no colliding variable" do
      source = """
      defmodule SchemaPlacerNoCollision do
        def value(a), do: {a, 1, 2}
      end
      """

      {rendered, [first_id, _second_id]} = instrument_literals!("no_collision", source)

      assert rendered =~ "mutalisk_schema_active = :persistent_term.get"
      refute rendered =~ "mutalisk_schema_active_1"

      module = compile_module!(rendered)

      assert with_active(0, fn -> module.value(:x) end) == {:x, 1, 2}
      assert with_active(first_id, fn -> module.value(:x) end) == {:x, 0, 2}
    end

    test "a collision in one function does not rename the binding in another" do
      source = """
      defmodule SchemaPlacerPerFunction do
        def tainted(mutalisk_schema_active), do: {mutalisk_schema_active, 1, 2}
        def clean(a), do: {a, 3, 4}
      end
      """

      {rendered, _ids} = instrument_literals!("per_function", source)

      assert rendered =~ "mutalisk_schema_active_1 = :persistent_term.get"
      assert rendered =~ "mutalisk_schema_active = :persistent_term.get"
    end

    test "skips numbered variants that are themselves taken" do
      source = """
      defmodule SchemaPlacerNumbered do
        def value(mutalisk_schema_active, mutalisk_schema_active_1) do
          {mutalisk_schema_active, mutalisk_schema_active_1, 1, 2}
        end
      end
      """

      {rendered, [first_id, _second_id]} = instrument_literals!("numbered", source)

      assert rendered =~ "mutalisk_schema_active_2 = :persistent_term.get"

      module = compile_module!(rendered)

      assert with_active(0, fn -> module.value(:a, :b) end) == {:a, :b, 1, 2}
      assert with_active(first_id, fn -> module.value(:a, :b) end) == {:a, :b, 0, 2}
    end

    test "the placement map still resolves arms behind a renamed scrutinee" do
      source = """
      defmodule SchemaPlacerRenamedMap do
        def value(mutalisk_schema_active), do: {mutalisk_schema_active, 1, 2}
      end
      """

      {file, mutants} = write_literal_mutants!("renamed_map", source)

      assert {:ok, _rendered, placement_map, []} = SchemaPlacer.instrument_file(file, mutants)
      assert Enum.flat_map(placement_map.entries, & &1.mut_ids) == Enum.map(mutants, & &1.id)
    end
  end

  # Instruments every scalar literal in `source` as a schema mutant that
  # rewrites the literal to `0`, then renders it exactly as the schema build
  # does (source round-trip). Returns the rendered source and the mutant ids.
  defp instrument_literals!(name, source) do
    {file, mutants} = write_literal_mutants!(name, source)

    assert {:ok, rendered, _placement_map, []} = SchemaPlacer.instrument_file(file, mutants)
    {rendered, Enum.map(mutants, & &1.id)}
  end

  defp write_literal_mutants!(name, source) do
    dir =
      Path.join(["tmp", "schema_placer_test", "#{name}_#{System.unique_integer([:positive])}"])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    file = Path.join(dir, "#{name}.ex")
    File.write!(file, source)

    mutants =
      [file: file, source: source]
      |> Mut.AstWalk.schema_literal_candidates()
      |> Enum.with_index(11)
      |> Enum.map(fn {candidate, id} ->
        %Mutant{
          mutant(candidate.ast_path_hash, id, 0)
          | mutator: Mut.Mutator.IntegerLiteral,
            mutator_name: "IntegerLiteral",
            mutation_kind: :integer_literal,
            original_dispatch: nil,
            file: file
        }
      end)

    {file, mutants}
  end

  defp compile_module!(rendered) do
    [{module, _binary}] = Code.compile_string(rendered, "rendered.ex")
    on_exit(fn -> :code.purge(module) && :code.delete(module) end)
    module
  end

  defp with_active(id, fun) do
    Mut.Runtime.set_active(id)
    fun.()
  after
    Mut.Runtime.clear()
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
