defmodule Mut.Match do
  @moduledoc "Attaches source AST candidates to oracle sites."

  alias Mut.Oracle
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @type diagnostic ::
          {:ambiguous_oracle_match, AstCandidate.t(), [DispatchSite.t()]}
          | {:missing_oracle_site, AstCandidate.t(), []}

  @spec attach([AstCandidate.t()], Oracle.t(), mutators :: [module] | nil) ::
          {[{AstCandidate.t(), DispatchSite.t()}], [diagnostic]}
  def attach(candidates, %Oracle{} = oracle, mutators \\ nil) do
    mutators = mutators || Mut.Match.Registry.list()
    columnless_candidate_index = build_columnless_candidate_index(candidates)

    candidates
    |> Enum.reduce({[], []}, fn candidate, {matched, diagnostics} ->
      pairs = compatible_pairs(candidate, oracle, mutators, columnless_candidate_index)

      case resolve_pairs(candidate, pairs) do
        {:matched, pair} -> {[pair | matched], diagnostics}
        {:diagnostic, diagnostic} -> {matched, [diagnostic | diagnostics]}
      end
    end)
    |> then(fn {matched, diagnostics} -> {Enum.reverse(matched), Enum.reverse(diagnostics)} end)
  end

  @doc false
  @spec build_oracle_index(Oracle.t()) :: %{optional(Oracle.key()) => [DispatchSite.t()]}
  def build_oracle_index(%Oracle{sites: sites}) do
    Enum.group_by(sites, &Oracle.primary_key/1)
  end

  @doc false
  @spec build_columnless_oracle_index(Oracle.t()) :: %{optional(tuple) => [DispatchSite.t()]}
  def build_columnless_oracle_index(%Oracle{sites: sites}) do
    sites
    |> Enum.filter(&is_nil(&1.column))
    |> Enum.group_by(&{&1.file, &1.line, &1.dispatch_kind, &1.resolved_name, &1.resolved_arity})
  end

  @doc false
  @spec build_candidate_index([AstCandidate.t()]) :: %{optional(tuple) => [AstCandidate.t()]}
  def build_candidate_index(candidates) do
    Enum.group_by(candidates, &candidate_key/1)
  end

  defp build_columnless_candidate_index(candidates) do
    Enum.group_by(candidates, &{&1.file, &1.line, &1.syntactic_name, &1.syntactic_arity})
  end

  defp compatible_pairs(candidate, %Oracle{} = oracle, mutators, columnless_candidate_index) do
    oracle
    |> sites_at(candidate.file, candidate.line)
    |> Enum.filter(fn site ->
      column_present?(site, candidate, columnless_candidate_index) and
        compatible?(candidate, site, mutators)
    end)
    |> Enum.uniq()
    |> Enum.map(&{candidate, &1})
  end

  defp sites_at(%Oracle{by_file_line: by_file_line}, file, line) do
    Map.get(by_file_line, {file, line}, [])
  end

  defp column_present?(%DispatchSite{column: nil} = site, candidate, columnless_candidate_index) do
    key = {candidate.file, candidate.line, candidate.syntactic_name, candidate.syntactic_arity}

    candidate.syntactic_name == site.resolved_name and
      candidate.syntactic_arity == site.resolved_arity and
      length(Map.get(columnless_candidate_index, key, [])) == 1
  end

  defp column_present?(
         %DispatchSite{column: site_column},
         %AstCandidate{column: candidate_column},
         _index
       )
       when is_integer(site_column) and is_integer(candidate_column),
       do: site_column == candidate_column

  defp column_present?(%DispatchSite{}, %AstCandidate{column: nil}, _index), do: true

  defp compatible?(candidate, site, mutators) do
    Enum.any?(mutators, fn mutator ->
      Code.ensure_loaded?(mutator) and function_exported?(mutator, :compatible?, 2) and
        mutator.compatible?(candidate, site)
    end)
  end

  defp resolve_pairs(candidate, []), do: {:diagnostic, {:missing_oracle_site, candidate, []}}
  defp resolve_pairs(_candidate, [pair]), do: {:matched, pair}

  defp resolve_pairs(candidate, pairs) do
    case refine_by_span(pairs) do
      [pair] ->
        {:matched, pair}

      span_pairs ->
        case dedupe_by_path_hash(span_pairs) do
          [pair] ->
            {:matched, pair}

          deduped ->
            {:diagnostic, {:ambiguous_oracle_match, candidate, Enum.map(deduped, &elem(&1, 1))}}
        end
    end
  end

  defp refine_by_span(pairs) do
    contained = Enum.filter(pairs, fn {candidate, site} -> span_contains?(candidate, site) end)
    if contained == [], do: pairs, else: contained
  end

  defp span_contains?(%AstCandidate{source_span: nil}, _site), do: false

  defp span_contains?(%AstCandidate{source_span: span}, %DispatchSite{} = site) do
    site_column = site.column || Keyword.get(site.meta, :column)

    is_integer(site_column) and span.start_line <= site.line and site.line <= span.end_line and
      starts_before_or_at?(span, site, site_column) and ends_after_or_at?(span, site, site_column)
  end

  defp starts_before_or_at?(span, site, site_column) when span.start_line == site.line,
    do: is_nil(span.start_column) or span.start_column <= site_column

  defp starts_before_or_at?(_span, _site, _site_column), do: true

  defp ends_after_or_at?(span, site, site_column) when span.end_line == site.line,
    do: is_nil(span.end_column) or site_column <= span.end_column

  defp ends_after_or_at?(_span, _site, _site_column), do: true

  defp dedupe_by_path_hash(pairs) do
    pairs
    |> Enum.group_by(fn {candidate, site} -> {candidate.ast_path_hash, site} end)
    |> Enum.map(fn {_key, [pair | _duplicates]} -> pair end)
  end

  defp candidate_key(candidate) do
    {candidate.file, candidate.line, candidate.column, candidate.syntactic_name,
     candidate.syntactic_arity}
  end
end
