defmodule Mut.SchemaPlacer.RoundTripTest do
  use ExUnit.Case, async: false

  @moduledoc false

  @fixture_root Path.expand("test/fixtures/demo_app")
  @arith_file Path.join(@fixture_root, "lib/arith.ex")

  setup do
    Mut.Runtime.clear()
    on_exit(fn -> Mut.Runtime.clear() end)
  end

  test "instrumented arith fixture compiles and selects schema mutants" do
    module = unique_module()
    mutants = arith_mutants()

    assert {:ok, rendered} = Mut.SchemaPlacer.instrument_file(@arith_file, mutants)

    rendered =
      String.replace(rendered, "defmodule Arith do", "defmodule #{module} do", global: false)

    Code.compile_string(rendered, "arith_schema_test.ex")

    Mut.Runtime.set_active(0)
    assert module.score(3, 5) == -16
    assert module.integer_parts(8, 3) == {2, 2}

    expectations = %{
      3 => {:score, [3, 5], -4.0},
      4 => {:score, [3, 5], -30},
      6 => {:score, [3, 5], 120},
      8 => {:score, [3, 5], 64},
      17 => {:integer_parts, [8, 3], {2, 2}},
      18 => {:score, [3, 5], 6},
      19 => {:score, [3, 5], 10},
      27 => {:integer_parts, [8, 3], {2, 2}},
      28 => {:score, [3, 5], 4}
    }

    for {id, {function, args, expected}} <- expectations do
      Mut.Runtime.set_active(id)
      assert apply(module, function, args) == expected
    end
  end

  defp arith_mutants do
    @fixture_root
    |> Mut.Orchestrator.plan(Mut.FixtureOracleHelper.golden_oracle())
    |> Map.fetch!(:schema)
    |> Enum.filter(&(&1.file == "lib/arith.ex"))
  end

  defp unique_module do
    suffix = :erlang.unique_integer([:positive])
    Module.concat([:"ArithSchemaTest_#{suffix}"])
  end
end
