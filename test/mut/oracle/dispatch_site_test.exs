defmodule Mut.Oracle.DispatchSiteTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "builds with defaults and required fields" do
    site = %Mut.Oracle.DispatchSite{
      file: "lib/example.ex",
      line: 1,
      dispatch_kind: :remote_function,
      resolved_name: :+,
      resolved_arity: 2,
      event_file: "lib/example.ex"
    }

    assert %Mut.Oracle.DispatchSite{} = site
    assert site.column == nil
    assert site.env_context == nil
    assert site.meta == []

    assert_raise ArgumentError, fn -> struct!(Mut.Oracle.DispatchSite, []) end
  end

  test "typespec accepts constructed values" do
    site = dispatch_site()

    assert site.file == "lib/example.ex"
    assert site.line == 1
    assert site.column == 3
    assert site.end_line == 1
    assert site.end_column == 8
    assert site.env_context == :guard
    assert site.module == Example
    assert site.function == {:sum, 2}
    assert site.dispatch_kind == :remote_function
    assert site.resolved_module == Kernel
    assert site.resolved_name == :+
    assert site.resolved_arity == 2
    assert site.event_file == "lib/example.ex"
    assert site.meta == [line: 1, column: 3]
  end

  test "Jason round-trip has expected keys" do
    jsonable_site = %{dispatch_site() | function: nil, meta: %{line: 1, column: 3}}

    keys =
      jsonable_site
      |> Jason.encode!()
      |> Jason.decode!()
      |> Map.keys()
      |> Enum.sort()

    assert keys ==
             ~w(column dispatch_kind end_column end_line env_context event_file file function line meta module resolved_arity resolved_module resolved_name)
  end

  @spec dispatch_site() :: Mut.Oracle.DispatchSite.t()
  defp dispatch_site do
    %Mut.Oracle.DispatchSite{
      file: "lib/example.ex",
      line: 1,
      column: 3,
      end_line: 1,
      end_column: 8,
      env_context: :guard,
      module: Example,
      function: {:sum, 2},
      dispatch_kind: :remote_function,
      resolved_module: Kernel,
      resolved_name: :+,
      resolved_arity: 2,
      event_file: "lib/example.ex",
      meta: [line: 1, column: 3]
    }
  end
end
