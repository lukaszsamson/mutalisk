defmodule Mut.MatchIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  alias Mut.Oracle
  alias Mut.Oracle.DispatchSite

  @fixture_root Path.expand("test/fixtures/demo_app")
  @golden Path.expand("test/golden/oracle/demo_app.json")

  test "matches fixture candidates against the committed oracle" do
    oracle = golden_oracle()
    {_candidates, matched, diagnostics} = match_fixture(oracle)

    assert_arith_operator_matched(matched, :+, 8)
    assert_arith_operator_matched(matched, :-, 18)
    assert_arith_operator_matched(matched, :*, 13)

    dsl_matches =
      Enum.filter(matched, fn {candidate, _site} -> candidate.file == "lib/dsl_user.ex" end)

    assert Enum.any?(dsl_matches, fn {_candidate, site} -> site.resolved_name == :defadd end)

    assert Enum.all?(dsl_matches, fn {_candidate, site} ->
             site.resolved_module == DslDef and site.resolved_name in [:defadd, :defadd_keep]
           end)

    meaningful = user_meaningful_matches(matched)

    diagnostic_candidates =
      Enum.map(diagnostics, fn {_reason, candidate, _sites} -> candidate end)

    assert Enum.all?(meaningful, fn {candidate, _site} ->
             candidate not in diagnostic_candidates
           end)
  end

  defp assert_arith_operator_matched(matched, name, column) do
    assert Enum.any?(matched, fn {candidate, site} ->
             candidate.file == "lib/arith.ex" and candidate.line == 5 and
               candidate.column == column and candidate.syntactic_name == name and
               site.resolved_module == Kernel and site.resolved_name == name and
               site.resolved_arity == 2
           end)
  end

  defp match_fixture(oracle) do
    candidates =
      @fixture_root
      |> Path.join("lib/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        rel = Path.relative_to(file, @fixture_root)
        {:ok, {ast, source}} = Mut.SourceParse.parse(file)
        Mut.AstWalk.dispatch_candidates(ast, file: rel, source: source)
      end)

    {matched, diagnostics} = Mut.Match.attach(candidates, oracle)
    {candidates, matched, diagnostics}
  end

  defp user_meaningful_matches(matched) do
    Enum.filter(matched, fn {candidate, _site} ->
      candidate.file in ~w(lib/arith.ex lib/attrs.ex lib/bool.ex lib/cmp.ex lib/dsl_user.ex lib/guards.ex) and
        candidate.syntactic_name in [
          :+,
          :-,
          :*,
          :div,
          :rem,
          :<,
          :<=,
          :>,
          :>=,
          :==,
          :!=,
          :and,
          :not,
          :!,
          :defadd,
          :defadd_keep
        ]
    end)
  end

  defp golden_oracle do
    @golden
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&decode_site/1)
    |> oracle()
  end

  defp oracle(sites) do
    Enum.reduce(sites, %Oracle{}, fn site, store ->
      key = Oracle.primary_key(site)
      file_line = {site.file, site.line}

      %{
        store
        | sites: store.sites ++ [site],
          by_key: Map.update(store.by_key, key, [site], &(&1 ++ [site])),
          by_file_line: Map.update(store.by_file_line, file_line, [site], &(&1 ++ [site]))
      }
    end)
  end

  defp decode_site(map) do
    %DispatchSite{
      file: map["file"],
      line: map["line"],
      column: map["column"],
      end_line: map["end_line"],
      end_column: map["end_column"],
      env_context: decode_atom(map["env_context"]),
      module: decode_module(map["module"]),
      function: decode_function(map["function"]),
      dispatch_kind: decode_atom(map["dispatch_kind"]),
      resolved_module: decode_module(map["resolved_module"]),
      resolved_name: decode_atom(map["resolved_name"]),
      resolved_arity: map["resolved_arity"],
      event_file: map["event_file"],
      meta: Enum.map(map["meta"] || [], fn [key, value] -> {decode_atom(key), value} end)
    }
  end

  defp decode_function(nil), do: nil
  defp decode_function([name, arity]), do: {decode_atom(name), arity}

  defp decode_module(nil), do: nil
  defp decode_module(module), do: String.to_atom(module)

  defp decode_atom(nil), do: nil
  defp decode_atom(value) when is_binary(value), do: String.to_atom(value)
end
