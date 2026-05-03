defmodule Mut.MatchTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Oracle
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite
  alias Mut.SourceSpan

  setup do
    Mut.Match.Registry.clear()
    :persistent_term.erase({__MODULE__.RecordingMutator, :calls})
    :ok
  end

  test "registry defaults to AlwaysCompatible and can be reset" do
    assert Mut.Match.Registry.list() == [Mut.Match.AlwaysCompatible]
    assert :ok = Mut.Match.Registry.register(RecordingMutator)
    assert Mut.Match.Registry.list() == [RecordingMutator, Mut.Match.AlwaysCompatible]
    assert :ok = Mut.Match.Registry.clear()
    assert Mut.Match.Registry.list() == [Mut.Match.AlwaysCompatible]
  end

  test "step 1 oracle index includes multiple sites under the same key" do
    first = site(column: 3)
    second = site(column: 3, resolved_module: :erlang)

    index = Mut.Match.build_oracle_index(oracle([first, second]))

    assert Map.fetch!(index, Oracle.primary_key(first)) == [first, second]
  end

  test "step 1 columnless oracle index is keyed without column" do
    first = site(column: nil)
    second = site(column: nil, resolved_module: :erlang)

    index = Mut.Match.build_columnless_oracle_index(oracle([first, second]))

    assert Map.fetch!(index, {"lib/a.ex", 1, :remote_function, :+, 2}) == [first, second]
  end

  test "step 2 candidate index keeps same source key with different path hashes" do
    first = candidate(ast_path_hash: "a")
    second = candidate(ast_path_hash: "b")

    index = Mut.Match.build_candidate_index([first, second])

    assert Map.fetch!(index, {"lib/a.ex", 1, 3, :+, 2}) == [first, second]
  end

  test "step 3 compatibility hook is called for registered mutators" do
    candidate = candidate()
    site = site()

    assert {[_match], []} =
             Mut.Match.attach([candidate], oracle([site]), [__MODULE__.RecordingMutator])

    assert [{^candidate, ^site}] = :persistent_term.get({__MODULE__.RecordingMutator, :calls})
  end

  test "step 4 single compatible pair is matched" do
    candidate = candidate()
    site = site()

    assert {[{^candidate, ^site}], []} = Mut.Match.attach([candidate], oracle([site]))
  end

  test "step 5 refines multiple matches by source span" do
    candidate = candidate(source_span: span(1, 1, 1, 4))
    inside = site(column: nil, meta: [line: 1, column: 3])
    outside = site(column: nil, resolved_module: :erlang, meta: [line: 1, column: 8])

    assert {[{^candidate, ^inside}], []} =
             Mut.Match.attach([candidate], oracle([inside, outside]))
  end

  test "step 5 dedupes canonical pairs by ast path hash" do
    candidate = candidate(ast_path_hash: "same")
    duplicate = site(column: nil)

    assert {[{^candidate, ^duplicate}], []} =
             Mut.Match.attach([candidate], oracle([duplicate, duplicate]))
  end

  test "step 5 keeps distinct oracle records ambiguous after path hash dedupe" do
    candidate = candidate(ast_path_hash: "same")
    first = site(column: nil)
    second = site(column: nil, resolved_module: :erlang)

    assert {[], [{:ambiguous_oracle_match, ^candidate, sites}]} =
             Mut.Match.attach([candidate], oracle([first, second]))

    assert sites == [first, second]
  end

  test "step 6 still ambiguous same-column matches emit diagnostics" do
    candidate = candidate(source_span: span(1, 1, 1, 10))
    first = site(column: 3)
    second = site(column: 3, resolved_module: :erlang)

    assert {[], [{:ambiguous_oracle_match, ^candidate, sites}]} =
             Mut.Match.attach([candidate], oracle([first, second]))

    assert sites == [first, second]
  end

  test "columned oracle sites match only candidates at the same column" do
    first = candidate(column: 7, ast_path_hash: "a")
    second = candidate(column: 12, ast_path_hash: "b")
    first_site = site(column: 7)
    second_site = site(column: 12)

    assert {[{^first, ^first_site}, {^second, ^second_site}], []} =
             Mut.Match.attach([first, second], oracle([first_site, second_site]))
  end

  test "step 7 missing compatible site emits diagnostics" do
    candidate = candidate(syntactic_name: :-)

    assert {[], [{:missing_oracle_site, ^candidate, []}]} =
             Mut.Match.attach([candidate], oracle([site()]))
  end

  test "columnless oracle site matches a unique same-line candidate" do
    candidate = candidate(column: 3)
    site = site(column: nil)

    assert {[{^candidate, ^site}], []} = Mut.Match.attach([candidate], oracle([site]))
  end

  test "columnless oracle site is skipped with multiple same-line candidates" do
    first = candidate(column: 3, ast_path_hash: "a")
    second = candidate(column: 8, ast_path_hash: "b")
    site = site(column: nil)

    assert {[], [{:missing_oracle_site, ^first, []}, {:missing_oracle_site, ^second, []}]} =
             Mut.Match.attach([first, second], oracle([site]))
  end

  test "orphan oracle site emits no diagnostic" do
    assert {[], []} = Mut.Match.attach([], oracle([site()]))
  end

  defmodule RecordingMutator do
    @moduledoc false

    def compatible?(candidate, site) do
      :persistent_term.put(
        {__MODULE__, :calls},
        [{candidate, site} | :persistent_term.get({__MODULE__, :calls}, [])]
      )

      true
    end
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

  defp candidate(opts \\ []) do
    %AstCandidate{
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: Keyword.get(opts, :line, 1),
      column: Keyword.get(opts, :column, 3),
      syntactic_name: Keyword.get(opts, :syntactic_name, :+),
      syntactic_arity: Keyword.get(opts, :syntactic_arity, 2),
      source_span: Keyword.get(opts, :source_span),
      ast_path: Keyword.get(opts, :ast_path, []),
      ast_path_hash: Keyword.get(opts, :ast_path_hash, "hash"),
      node: Keyword.get(opts, :node, {:+, [], [1, 2]})
    }
  end

  defp site(opts \\ []) do
    %DispatchSite{
      file: Keyword.get(opts, :file, "lib/a.ex"),
      line: Keyword.get(opts, :line, 1),
      column: Keyword.get(opts, :column, 3),
      end_column: Keyword.get(opts, :end_column),
      dispatch_kind: Keyword.get(opts, :dispatch_kind, :remote_function),
      resolved_module: Keyword.get(opts, :resolved_module, Kernel),
      resolved_name: Keyword.get(opts, :resolved_name, :+),
      resolved_arity: Keyword.get(opts, :resolved_arity, 2),
      event_file: Keyword.get(opts, :event_file, "lib/a.ex"),
      meta: Keyword.get(opts, :meta, [])
    }
  end

  defp span(start_line, start_column, end_line, end_column) do
    %SourceSpan{
      file: "lib/a.ex",
      start_line: start_line,
      start_column: start_column,
      end_line: end_line,
      end_column: end_column,
      start_byte: 0,
      end_byte: 0
    }
  end
end
