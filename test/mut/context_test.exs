defmodule Mut.ContextTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    context = %Mut.Context{
      file: "lib/example.ex",
      ast_path: [0, :body],
      ast_path_hash: "abc",
      engine: :schema
    }

    assert %Mut.Context{} = context
    assert context.oracle_site == nil
    assert context.env_context == nil

    assert_raise ArgumentError, fn -> struct!(Mut.Context, []) end
  end

  test "typespec accepts constructed values" do
    context = context()

    assert %Mut.Oracle.DispatchSite{} = context.oracle_site
    assert context.enclosing_function == {:sum, 2}
    assert context.enclosing_module == Example
    assert context.file == "lib/example.ex"
    assert %Mut.SourceSpan{} = context.source_span
    assert context.ast_path == [0, :body]
    assert context.ast_path_hash == "abc"
    assert context.env_context == :guard
    assert context.engine == :fallback
  end

  @spec context() :: Mut.Context.t()
  defp context do
    %Mut.Context{
      oracle_site: %Mut.Oracle.DispatchSite{
        file: "lib/example.ex",
        line: 1,
        dispatch_kind: :remote_function,
        resolved_name: :+,
        resolved_arity: 2,
        event_file: "lib/example.ex"
      },
      enclosing_function: {:sum, 2},
      enclosing_module: Example,
      file: "lib/example.ex",
      source_span: %Mut.SourceSpan{
        file: "lib/example.ex",
        start_line: 1,
        start_byte: 0,
        end_byte: 5
      },
      ast_path: [0, :body],
      ast_path_hash: "abc",
      env_context: :guard,
      engine: :fallback
    }
  end
end
