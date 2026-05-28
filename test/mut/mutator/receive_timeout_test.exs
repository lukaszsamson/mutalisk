defmodule Mut.Mutator.ReceiveTimeoutTest do
  use ExUnit.Case, async: true

  @moduledoc "M94 ReceiveTimeout + AstWalk.receive_timeout_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.ReceiveTimeout

  defp candidates(src) do
    ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
    AstWalk.receive_timeout_candidates(ast, file: "m.ex", source: src)
  end

  defp ctx(ast_path),
    do: %Context{engine: :fallback, file: "m.ex", ast_path: ast_path, ast_path_hash: "h"}

  describe "metadata" do
    test "name/targets" do
      assert ReceiveTimeout.name() == "ReceiveTimeout"
      assert ReceiveTimeout.targets() == [:receive_timeout]
    end
  end

  describe "AstWalk.receive_timeout_candidates" do
    test "skips receive without after" do
      src = """
      defmodule M do
        def f do
          receive do
            msg -> msg
          end
        end
      end
      """

      assert candidates(src) == []
    end

    test "emits one candidate per receive with after" do
      src = """
      defmodule M do
        def f do
          receive do
            :a -> :got_a
            :b -> :got_b
          after
            5000 -> :timeout
          end
        end
      end
      """

      cands = candidates(src)
      assert length(cands) == 1
      [c] = cands
      assert c.syntactic_name == :receive_timeout
    end
  end

  describe "ReceiveTimeout.mutate" do
    @src """
    defmodule M do
      def f do
        receive do
          msg -> msg
        after
          5000 -> :timeout
        end
      end
    end
    """

    test "emits three mutations: 0, :infinity, drop" do
      [c] = candidates(@src)
      muts = ReceiveTimeout.mutate(c.node, ctx(c.ast_path))
      assert length(muts) == 3

      changes = Enum.map(muts, & &1.metadata.change)
      assert changes == [{:set_timeout, 0}, {:set_timeout, :infinity}, :drop_after]
    end

    test "set 0 keeps the after body but flips timeout" do
      [c] = candidates(@src)
      [zero, _inf, _drop] = ReceiveTimeout.mutate(c.node, ctx(c.ast_path))
      assert {:receive, _, [args]} = zero.mutated_ast
      assert [{:->, _, [[0], :timeout]}] = Keyword.fetch!(args, :after)
    end

    test "drop variant removes the :after key entirely" do
      [c] = candidates(@src)
      [_zero, _inf, drop] = ReceiveTimeout.mutate(c.node, ctx(c.ast_path))
      assert {:receive, _, [args]} = drop.mutated_ast
      refute Keyword.has_key?(args, :after)
      assert Keyword.has_key?(args, :do)
    end

    test "not applicable in schema engine or on non-receive nodes" do
      [c] = candidates(@src)
      schema_ctx = %{ctx(c.ast_path) | engine: :schema}
      refute ReceiveTimeout.applicable?(c.node, schema_ctx)
      refute ReceiveTimeout.applicable?({:+, [], [1, 2]}, ctx([0]))
    end
  end
end
