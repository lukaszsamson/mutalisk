defmodule Mut.SchemaPlacer.GoldenInstrumentTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_instrument

  @fixture_root Path.expand("test/fixtures/demo_app")
  @golden_root Path.expand("test/golden/instrument")
  @fixture_files ~w(arith.ex cmp.ex bool.ex)

  test "fixture instrumented sources match golden files" do
    plan = Mut.Orchestrator.plan(@fixture_root, Mut.FixtureOracleHelper.golden_oracle())

    Enum.each(@fixture_files, fn file ->
      relative = "lib/#{file}"
      path = Path.join(@fixture_root, relative)
      mutants = Enum.filter(plan.schema, &(&1.file == relative))

      assert {:ok, actual, _placement_map} = Mut.SchemaPlacer.instrument_file(path, mutants)

      golden = Path.join(@golden_root, "#{Path.rootname(file)}.ex.txt")

      if System.get_env("MUT_REGOLD") == "1" do
        File.mkdir_p!(@golden_root)
        File.write!(golden, actual)
      end

      assert actual == File.read!(golden)
    end)
  end
end
