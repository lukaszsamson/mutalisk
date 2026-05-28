defmodule Mut.Mutator.PipelineDropStageTest do
  use ExUnit.Case, async: true

  @moduledoc "M94 PipelineDropStage + AstWalk.pipeline_drop_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.PipelineDropStage

  defp candidates(src) do
    ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
    AstWalk.pipeline_drop_candidates(ast, file: "m.ex", source: src)
  end

  defp ctx(ast_path),
    do: %Context{engine: :fallback, file: "m.ex", ast_path: ast_path, ast_path_hash: "h"}

  describe "metadata" do
    test "name/targets" do
      assert PipelineDropStage.name() == "PipelineDropStage"
      assert PipelineDropStage.targets() == [:pipeline_drop]
    end
  end

  describe "AstWalk.pipeline_drop_candidates" do
    test "skips 2-stage chains (no middle to drop)" do
      src = """
      defmodule M do
        def f(x), do: x |> Enum.sum()
      end
      """

      assert candidates(src) == []
    end

    test "skips 3-stage chains (first + last excluded, no middle)" do
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(&pos?/1)
          |> Enum.sum()
        end
      end
      """

      # 3 elements in flat list: [x, filter, sum]. n=3 → 2..(n-2) = 2..1, empty.
      # Actually n needs to be >= 4 — collector requires it.
      assert candidates(src) == []
    end

    test "4-stage chain emits one candidate (drop middle)" do
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(&pos?/1)
          |> Enum.map(&double/1)
          |> Enum.sum()
        end
      end
      """

      # flat: [x, filter, map, sum]. n=4. Deletable: index 2 (the `map`).
      cands = candidates(src)
      assert length(cands) == 1
      assert List.last(hd(cands).ast_path) == 2
    end

    test "5-stage chain emits two candidates (drop each middle)" do
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(&pos?/1)
          |> Enum.map(&double/1)
          |> Enum.sort()
          |> Enum.sum()
        end
      end
      """

      # flat: [x, filter, map, sort, sum]. n=5. Deletable: indexes 2, 3.
      cands = candidates(src)
      assert length(cands) == 2
      assert Enum.sort(Enum.map(cands, &List.last(&1.ast_path))) == [2, 3]
    end

    test "nested pipelines: only the top chain enumerates" do
      # Outer pipeline contains an inner-pipeline expression as part of one stage.
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(fn y -> y |> double() |> pos?() end)
          |> Enum.map(&triple/1)
          |> Enum.sum()
        end
      end
      """

      # The outer chain: [x, filter(fn), map, sum] → 4 elements, 1 candidate.
      # The inner chain inside the lambda: [y, double, pos?] → 3 elements,
      # 0 candidates by collector rules — and the collector prunes anyway.
      cands = candidates(src)
      assert length(cands) == 1
    end
  end

  describe "PipelineDropStage.mutate" do
    test "drops the indexed middle stage and rebuilds the pipeline" do
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(&pos?/1)
          |> Enum.map(&double/1)
          |> Enum.sum()
        end
      end
      """

      [c] = candidates(src)
      [m] = PipelineDropStage.mutate(c.node, ctx(c.ast_path))

      # Mutation drops index 2 (Enum.map). Resulting pipeline: x |> filter |> sum.
      rendered = Macro.to_string(m.mutated_ast)
      assert rendered =~ "filter"
      assert rendered =~ "sum"
      refute rendered =~ "map"
    end

    test "not applicable in schema engine or on non-|> nodes" do
      src = """
      defmodule M do
        def f(x) do
          x
          |> Enum.filter(&pos?/1)
          |> Enum.map(&double/1)
          |> Enum.sum()
        end
      end
      """

      [c] = candidates(src)
      schema_ctx = %{ctx(c.ast_path) | engine: :schema}
      refute PipelineDropStage.applicable?(c.node, schema_ctx)
      refute PipelineDropStage.applicable?({:+, [], [1, 2]}, ctx([0]))
    end
  end
end
