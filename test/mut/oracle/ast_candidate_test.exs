defmodule Mut.Oracle.AstCandidateTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    candidate = %Mut.Oracle.AstCandidate{
      file: "lib/example.ex",
      line: 1,
      syntactic_name: :+,
      syntactic_arity: 2,
      ast_path: [0, :body],
      ast_path_hash: "abc",
      node: {:+, [], [1, 2]}
    }

    assert %Mut.Oracle.AstCandidate{} = candidate
    assert candidate.column == nil
    assert candidate.source_span == nil

    assert_raise ArgumentError, fn -> struct!(Mut.Oracle.AstCandidate, []) end
  end

  test "typespec accepts constructed values" do
    candidate = ast_candidate()

    assert candidate.file == "lib/example.ex"
    assert candidate.line == 1
    assert candidate.column == 3
    assert candidate.syntactic_name == :+
    assert candidate.syntactic_arity == 2
    assert %Mut.SourceSpan{} = candidate.source_span
    assert candidate.ast_path == [0, :body]
    assert candidate.ast_path_hash == "abc"
    assert candidate.node == {:+, [], [1, 2]}
  end

  @spec ast_candidate() :: Mut.Oracle.AstCandidate.t()
  defp ast_candidate do
    %Mut.Oracle.AstCandidate{
      file: "lib/example.ex",
      line: 1,
      column: 3,
      syntactic_name: :+,
      syntactic_arity: 2,
      source_span: %Mut.SourceSpan{
        file: "lib/example.ex",
        start_line: 1,
        start_byte: 0,
        end_byte: 5
      },
      ast_path: [0, :body],
      ast_path_hash: "abc",
      node: {:+, [], [1, 2]}
    }
  end
end
