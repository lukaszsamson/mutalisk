defmodule Mut.OracleDslFilterTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  setup do
    assert {:ok, oracle} = Mut.OracleBuild.run(Path.expand("test/fixtures/demo_app"), force: true)
    %{sites: oracle.sites}
  end

  test "default quote expansion is filtered while macro call site is recorded", %{sites: sites} do
    refute Enum.any?(sites, &(&1.file == "lib/dsl_user.ex" and &1.resolved_name == :+))

    assert Enum.any?(sites, fn site ->
             site.file == "lib/dsl_user.ex" and site.resolved_module == DslDef and
               site.resolved_name == :defadd
           end)
  end

  @tag :known_limitation
  test "quote location keep observed behavior", %{sites: sites} do
    refute Enum.any?(sites, &(&1.file == "lib/dsl_user.ex" and &1.resolved_name == :+))

    assert Enum.any?(sites, fn site ->
             site.file == "lib/dsl_user.ex" and site.resolved_module == DslDef and
               site.resolved_name == :defadd_keep
           end)
  end
end
