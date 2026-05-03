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
      assert actual == File.read!(@golden), diff(actual, File.read!(@golden))
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

  defp diff(actual, expected) do
    String.myers_difference(expected, actual)
    |> Enum.map_join(fn
      {:eq, text} -> text
      {:del, text} -> "\n-" <> String.replace(text, "\n", "\n-")
      {:ins, text} -> "\n+" <> String.replace(text, "\n", "\n+")
    end)
  end
end
