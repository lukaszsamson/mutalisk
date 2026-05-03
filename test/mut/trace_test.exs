defmodule Mut.TraceTest do
  use ExUnit.Case, async: false

  @moduledoc false

  test "filters generated, cross-file, and line-less events" do
    env = env()

    assert %Mut.Oracle.DispatchSite{} =
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 1, column: 3], Kernel, :+, 2},
               env
             )

    assert nil ==
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 1, generated: true], Kernel, :+, 2},
               env
             )

    assert nil ==
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 1, file: "other.ex"], Kernel, :+, 2},
               env
             )

    assert nil == Mut.Trace.to_dispatch_site({:remote_function, [], Kernel, :+, 2}, env)
  end

  test "normalizes local and imported dispatch events" do
    env = env()

    assert %{dispatch_kind: :local_function, resolved_module: Example, resolved_name: :helper} =
             Mut.Trace.to_dispatch_site({:local_function, [line: 2], :helper, 1}, env)

    assert %{dispatch_kind: :imported_macro, resolved_module: Kernel, resolved_name: :is_integer} =
             Mut.Trace.to_dispatch_site({:imported_macro, [line: 3], Kernel, :is_integer, 1}, env)
  end

  test "keeps same-module macro context dispatch" do
    env = env(module: SameModuleDsl)

    assert %Mut.Oracle.DispatchSite{} =
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 4, context: SameModuleDsl], Kernel, :+, 2},
               env
             )
  end

  test "drops cross-module macro context dispatch" do
    env = env(module: MacroUser)

    assert nil ==
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 4, context: MacroDef], Kernel, :+, 2},
               env
             )
  end

  test "keeps anonymous module context dispatch when context matches env module" do
    module = Module.concat(AnonGenerated, "M#{System.unique_integer([:positive])}")
    env = env(module: module)

    assert %Mut.Oracle.DispatchSite{} =
             Mut.Trace.to_dispatch_site(
               {:remote_function, [line: 4, context: module], Kernel, :+, 2},
               env
             )
  end

  defp env(opts \\ []) do
    struct!(Macro.Env,
      file: Path.expand("lib/example.ex"),
      line: 1,
      module: Keyword.get(opts, :module, Example),
      function: {:run, 1},
      context: nil
    )
  end
end
