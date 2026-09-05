defmodule Mut.Mutator.StringLiteralTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.EnvWalker
  alias Mut.Mutator.StringLiteral

  describe "name/0 and metadata" do
    test "name is StringLiteral" do
      assert StringLiteral.name() == "StringLiteral"
    end

    test "targets :env_walker and :pattern_literal (M53)" do
      assert StringLiteral.targets() == [:env_walker, :pattern_literal]
    end
  end

  describe "applicable?/2" do
    defp ctx(overrides) do
      base = %Context{
        engine: :fallback,
        env_context: nil,
        file: "lib/foo.ex",
        ast_path: [],
        ast_path_hash: <<0>>
      }

      struct(base, overrides)
    end

    test "true for non-empty string body literal in fallback engine, body context" do
      node = {:__block__, [], ["hello"]}
      assert StringLiteral.applicable?(node, ctx([]))
    end

    test "false for empty string" do
      node = {:__block__, [], [""]}
      refute StringLiteral.applicable?(node, ctx([]))
    end

    test "false for non-binary values (atom, integer, boolean)" do
      refute StringLiteral.applicable?({:__block__, [], [:atom]}, ctx([]))
      refute StringLiteral.applicable?({:__block__, [], [42]}, ctx([]))
      refute StringLiteral.applicable?({:__block__, [], [true]}, ctx([]))
    end

    test "true in match context (M53 pattern-position literals)" do
      node = {:__block__, [], ["hi"]}
      assert StringLiteral.applicable?(node, ctx(env_context: :match))
    end

    test "false in guard context" do
      node = {:__block__, [], ["hi"]}
      refute StringLiteral.applicable?(node, ctx(env_context: :guard))
    end

    test "applicable under schema engine (M52 schema-routed)" do
      node = {:__block__, [], ["hi"]}
      assert StringLiteral.applicable?(node, ctx(engine: :schema))
    end
  end

  describe "mutate/2" do
    test "table is empty + x (M49 dropped the prepend-space row); M40 row unchanged" do
      node = {:__block__, [line: 1, column: 5], ["hello"]}
      ctx = ctx(engine: :fallback, env_context: nil)
      mutations = StringLiteral.mutate(node, ctx)

      assert Enum.all?(mutations, &(&1.mutation_kind == :string_literal))
      tos = Enum.map(mutations, & &1.metadata.to)
      assert tos == ["", "x"]

      # The M40 `→ ""` row must stay byte-identical so its stable ID
      # does not churn.
      [empty | _] = mutations
      assert empty.metadata == %{from: "hello", to: ""}
      assert match?({:__block__, _, [""]}, empty.mutated_ast)
      assert empty.description == "replace non-empty string literal with \"\""
    end

    test "the x-replacement row is dropped as equivalent when the source is already x" do
      node = {:__block__, [line: 1, column: 5], ["x"]}
      ctx = ctx(engine: :fallback, env_context: nil)

      mutations =
        node
        |> StringLiteral.mutate(ctx)
        |> Enum.reject(&StringLiteral.equivalent?/1)

      tos = Enum.map(mutations, & &1.metadata.to)
      assert tos == [""]
    end

    test "B17: heredoc replacements render as regular strings and reparse" do
      src = ~s(x = """\nhello\n""")

      {:ok, {:=, _, [_var, literal]}} =
        Code.string_to_quoted(src,
          columns: true,
          token_metadata: true,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}}
        )

      # The parsed literal really is heredoc-delimited.
      {:__block__, meta, ["hello\n"]} = literal
      assert Keyword.get(meta, :delimiter) == ~s(""")

      mutations = StringLiteral.mutate(literal, ctx(engine: :fallback, env_context: nil))
      assert length(mutations) == 2

      for mutation <- mutations do
        {:__block__, mutated_meta, [_value]} = mutation.mutated_ast
        refute Keyword.has_key?(mutated_meta, :delimiter)
        refute Keyword.has_key?(mutated_meta, :indentation)

        rendered = Macro.to_string(mutation.mutated_ast)
        assert {:ok, _} = Code.string_to_quoted(rendered)
        assert is_binary(IO.iodata_to_binary(Code.format_string!(rendered)))
      end

      # The `→ "x"` row is the one that used to render `"""\nx"""`.
      assert Enum.map(mutations, &Macro.to_string(&1.mutated_ast)) == [~s(""), ~s("x")]
    end

    test "non-heredoc string metadata is left untouched" do
      node = {:__block__, [delimiter: "\"", line: 1, column: 5], ["hello"]}
      [empty, x] = StringLiteral.mutate(node, ctx(engine: :fallback, env_context: nil))
      assert {:__block__, [delimiter: "\"", line: 1, column: 5], [""]} = empty.mutated_ast
      assert {:__block__, [delimiter: "\"", line: 1, column: 5], ["x"]} = x.mutated_ast
    end

    test "produces no mutations for ineligible nodes" do
      assert StringLiteral.mutate(
               {:__block__, [], [""]},
               ctx(engine: :fallback, env_context: nil)
             ) ==
               []

      assert StringLiteral.mutate(
               {:__block__, [], [42]},
               ctx(engine: :fallback, env_context: nil)
             ) ==
               []
    end
  end

  describe "end-to-end via env walker" do
    test "collects a string-literal candidate from a function body" do
      src = ~S'''
      defmodule Foo do
        def x do
          "hello"
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert length(pairs) == 1
      [{candidate, snap}] = pairs
      assert candidate.syntactic_name == :__string_literal__
      assert {:__block__, _, ["hello"]} = candidate.node
      assert snap.scope == :function_body
      assert snap.trust_level == :trusted
    end

    test "does not collect literals in guards (M40 acceptance)" do
      src = ~S'''
      defmodule Foo do
        def x(s) when s == "guard-literal" do
          :ok
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert pairs == []
    end

    test "collects match-context literals with env_context :match (M53)" do
      src = ~S'''
      defmodule Foo do
        def x("pattern-literal") do
          :ok
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert [{candidate, snap}] = pairs
      assert {:__block__, _, ["pattern-literal"]} = candidate.node
      assert candidate.env_context == :match
      assert snap.context == :match
    end

    test "does not collect literals inside quote bodies (M40 acceptance)" do
      src = ~S'''
      defmodule Foo do
        def x do
          quote do
            "inside-quote"
          end
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert pairs == []
    end

    test "does not collect empty string literals" do
      src = ~S'''
      defmodule Foo do
        def x do
          ""
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert pairs == []
    end

    test "does not collect literals in defmacro bodies (scope :macro_definition)" do
      src = ~S'''
      defmodule Foo do
        defmacro mac do
          "macro-literal"
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_string_literal_candidates(ast, file: "lib/foo.ex", source: src)
      assert pairs == []
    end
  end
end
