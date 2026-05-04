defmodule Mut.Coverage.ParserTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Coverage.Parser

  @fixture_root Path.expand("test/support")
  @test_id {:file, "test/parser_fixture_test.exs"}

  test "parses OTP 28 result tuples into line and function maps" do
    line = {:result, [{{Mut.CoverageParserFixture, 4}, {1, 0}}, {{String, 10}, {0, 1}}]}

    function =
      {:result,
       [{{Mut.CoverageParserFixture, :touched, 0}, {1, 0}}, {{String, :upcase, 1}, {0, 1}}]}

    {by_line, by_function} = Parser.parse(line, function, @test_id, @fixture_root)

    assert MapSet.member?(by_line[{"coverage_parser_fixture.ex", 4}], @test_id)
    assert MapSet.member?(by_function[{Mut.CoverageParserFixture, :touched, 0}], @test_id)
    refute Map.has_key?(by_function, {String, :upcase, 1})
  end

  test "parses older ok tuple shapes" do
    line = {:ok, [{{Mut.CoverageParserFixture, 4}, {2, 1}}]}
    function = {:ok, [{{Mut.CoverageParserFixture, :touched, 0}, {2, 1}}]}

    {by_line, by_function} = Parser.parse(line, function, @test_id, @fixture_root)

    assert MapSet.member?(by_line[{"coverage_parser_fixture.ex", 4}], @test_id)
    assert MapSet.member?(by_function[{Mut.CoverageParserFixture, :touched, 0}], @test_id)
  end

  test "parses three-element cover tuple shapes" do
    line = {:ok, [{{Mut.CoverageParserFixture, 4}, {1, 0}}], []}
    function = {:ok, [{{Mut.CoverageParserFixture, :touched, 0}, {1, 0}}], []}

    {by_line, by_function} = Parser.parse(line, function, @test_id, @fixture_root)

    assert MapSet.member?(by_line[{"coverage_parser_fixture.ex", 4}], @test_id)
    assert MapSet.member?(by_function[{Mut.CoverageParserFixture, :touched, 0}], @test_id)
  end

  test "ignores line hits for modules without compile source" do
    line = {:result, [{{:mutalisk_generated_coverage_fixture, 12}, {1, 0}}]}
    function = {:result, [{{:mutalisk_generated_coverage_fixture, :run, 0}, {1, 0}}]}

    {by_line, by_function} = Parser.parse(line, function, @test_id, @fixture_root)

    assert by_line == %{}
    assert by_function == %{}
  end

  test "returns empty maps for failed cover analysis" do
    assert Parser.parse({:error, :not_started}, {:error, :not_started}, @test_id, @fixture_root) ==
             {%{}, %{}}
  end
end
