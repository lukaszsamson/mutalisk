defmodule Mut.OracleBuildTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  @golden Path.expand("test/golden/oracle/demo_app.json")

  test "builds demo app oracle matching golden file" do
    assert {:ok, _oracle} = Mut.OracleBuild.run(demo_app(), force: true)

    actual = dump_oracle()

    if System.get_env("MUT_REGOLD") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, actual)
    else
      expected = File.read!(@golden)

      assert comparable_oracle(actual) == comparable_oracle(expected), diff(actual, expected)
    end
  end

  defp demo_app do
    Path.expand("test/fixtures/demo_app")
  end

  defp dump_oracle do
    {:ok, io} = StringIO.open("")
    Mut.Oracle.dump_json(io)
    {_input, output} = StringIO.contents(io)
    output
  end

  defp comparable_oracle(json) do
    json
    |> Mut.JSON.decode!()
    |> Enum.reject(&compile_time_module_dispatch?/1)
    |> Mut.JSON.encode!(pretty: true)
  end

  # The `:elixir_*` Erlang modules (`:elixir_quote`, `:elixir_utils`, …) are
  # the compiler's own internals, injected when it processes quote/macros —
  # never user-source dispatches, never mutation targets. Their names drift
  # across Elixir versions (1.20 renamed `:elixir_quote.shallow_validate_ast/1`
  # to `:elixir_quote.unquote/1`), so filter them out to keep the golden
  # version-tolerant rather than pinning it to one compiler release.
  defp compile_time_module_dispatch?(%{"resolved_module" => "elixir_" <> _}), do: true

  defp compile_time_module_dispatch?(%{"column" => nil, "resolved_module" => module})
       when module in ["Elixir.Module", "Elixir.Kernel", "erlang"] do
    true
  end

  defp compile_time_module_dispatch?(_entry), do: false

  defp diff(actual, expected) do
    String.myers_difference(expected, actual)
    |> Enum.map_join(fn
      {:eq, text} -> text
      {:del, text} -> "\n-" <> String.replace(text, "\n", "\n-")
      {:ins, text} -> "\n+" <> String.replace(text, "\n", "\n+")
    end)
  end
end
