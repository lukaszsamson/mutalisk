defmodule Mut.Reporter.StrykerJson do
  @moduledoc "Renders and validates Stryker mutation-testing-elements JSON."

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Plan

  @statuses %{
    killed: "Killed",
    survived: "Survived",
    timeout: "Timeout",
    invalid: "CompileError",
    error: "RuntimeError",
    skipped: "Ignored"
  }

  @valid_statuses Map.values(@statuses)

  @type violation :: String.t()

  @spec render(Snapshot.t(), Plan.t(), (Path.t() -> String.t()), keyword) :: map()
  def render(%Snapshot{} = snapshot, %Plan{} = plan, source_loader, opts)
      when is_function(source_loader, 1) do
    thresholds = Keyword.get(opts, :thresholds, %{"high" => 80, "low" => 60})

    mutants =
      snapshot.ledger
      |> Enum.map(&ledger_mutant/1)
      |> Enum.reject(&(is_nil(&1) or &1.status == :pending))
      |> Enum.sort_by(&{&1.file, &1.stable_id})

    %{
      "schemaVersion" => "2",
      "thresholds" => thresholds,
      "files" => files(mutants, snapshot, source_loader),
      "mutalisk" => mutalisk_extension(plan, mutants, snapshot)
    }
  end

  @spec write(rendered :: map(), path :: Path.t()) :: :ok
  def write(rendered, path) when is_map(rendered) and is_binary(path) do
    File.write!(path, Mut.JSON.encode!(rendered, pretty: true) <> "\n")
    :ok
  end

  @spec validate(rendered :: map()) :: :ok | {:error, [violation()]}
  def validate(rendered) when is_map(rendered) do
    violations =
      []
      |> validate_schema_version(rendered)
      |> validate_thresholds(rendered)
      |> validate_files(rendered)
      |> Enum.reverse()

    if violations == [], do: :ok, else: {:error, violations}
  end

  @spec status(Mutant.status()) :: String.t() | nil
  def status(:pending), do: nil
  def status(status), do: Map.fetch!(@statuses, status)

  defp files(mutants, snapshot, source_loader) do
    mutants
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _mutants} -> file end)
    |> Map.new(fn {file, file_mutants} ->
      {file,
       %{
         "language" => "elixir",
         "source" => source_loader.(file),
         "mutants" => Enum.map(file_mutants, &mutant_result(&1, snapshot))
       }}
    end)
  end

  defp mutant_result(%Mutant{} = mutant, snapshot) do
    entry = Enum.find(snapshot.ledger, &(Map.get(&1, :stable_id) == mutant.stable_id)) || %{}
    status = Map.get(entry, :status, mutant.status)

    %{
      "id" => mutant.stable_id,
      "mutatorName" => mutant.mutator_name,
      "replacement" => replacement(mutant),
      "location" => location(mutant),
      "status" => status(status),
      "killedBy" => killed_by(entry),
      "coveredBy" => covered_by(mutant),
      "duration" => duration(mutant, entry),
      "description" => mutant.description
    }
    |> put_optional("statusReason", status_reason(mutant, entry, status))
  end

  defp mutalisk_extension(%Plan{} = plan, mutants, snapshot) do
    planned = plan.schema ++ plan.fallback ++ plan.invalid
    by_stable_id = Map.new(planned, &{&1.stable_id, &1})

    base = %{
      "stable_id_to_integer" => Map.new(mutants, &{&1.stable_id, &1.id}),
      "engine" => Map.new(mutants, &{&1.stable_id, Atom.to_string(&1.engine)}),
      "mutation_kind" =>
        Map.new(mutants, fn mutant ->
          planned_mutant = Map.get(by_stable_id, mutant.stable_id, mutant)
          {mutant.stable_id, atom_string(planned_mutant.mutation_kind)}
        end),
      "phase_timings" => stringify_keys(snapshot.phase_timings || %{}),
      "selection" => selection_extension(snapshot.selection || %{}),
      "metrics" => metrics_extension(snapshot),
      "concurrency" => concurrency_extension(snapshot.concurrency),
      "recompile_categories" => recompile_categories_extension(snapshot.recompile_categories),
      "test_timeout_ms" => snapshot.test_timeout_ms || 10_000
    }

    # M106: only emit the reused-vs-executed split when `--incremental` actually
    # reused a verdict — so a non-incremental report stays byte-identical to
    # v1.28 (no new key).
    put_incremental(base, snapshot)
  end

  defp put_incremental(base, %{reused: reused, total: total} = snapshot)
       when is_integer(reused) and reused > 0,
       do:
         Map.put(base, "incremental", %{
           "reused" => reused,
           "executed" => max((total || 0) - reused, 0),
           "reused_ids" => Map.get(snapshot, :reused_ids, [])
         })

  defp put_incremental(base, _snapshot), do: base

  defp recompile_categories_extension(nil), do: %{}
  defp recompile_categories_extension(%{} = cats), do: atom_keyed_counts(cats)

  defp concurrency_extension(nil) do
    schedulers = System.schedulers_online()
    %{"configured" => 1, "effective" => 1, "schedulers_online" => schedulers}
  end

  defp concurrency_extension(%{} = c) do
    %{
      "configured" => c.configured,
      "effective" => c.effective,
      "schedulers_online" => c.schedulers_online
    }
  end

  defp selection_extension(selection) do
    %{
      "mode" => atom_string(Map.get(selection, :mode)) || "static",
      "coverage_match_distribution" =>
        atom_keyed_counts(Map.get(selection, :coverage_match_distribution, %{})),
      "fallback_reason_distribution" =>
        atom_keyed_counts(Map.get(selection, :fallback_reason_distribution, %{})),
      "selected_tests_avg" => Map.get(selection, :selected_tests_avg, 0.0),
      "selected_tests_median" => Map.get(selection, :selected_tests_median, 0),
      "coverage_collection_wall_ms" => Map.get(selection, :coverage_collection_wall_ms, 0)
    }
  end

  defp metrics_extension(snapshot) do
    %{
      "fallback_count" => engine_count(snapshot, :fallback),
      "fallback_time_ms" => snapshot.wall_clock_ms.fallback,
      "rollback_count" => Enum.sum(Map.values(snapshot.rollback_per_file)),
      "invalid_mutants" => atom_keyed_counts(snapshot.invalid_by_mutator),
      "skipped" => atom_keyed_counts(snapshot.skipped_by_reason),
      "fanout" => snapshot.test_selection_fanout
    }
  end

  defp engine_count(snapshot, engine) do
    snapshot.by_engine_status
    |> Enum.filter(fn {{entry_engine, _status}, _count} -> entry_engine == engine end)
    |> Enum.reduce(0, fn {_key, count}, total -> total + count end)
  end

  defp atom_keyed_counts(counts) do
    Map.new(counts, fn {key, count} -> {atom_string(key) || inspect(key), count} end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp replacement(%Mutant{source_patch: %{replacement: replacement}})
       when is_binary(replacement) do
    replacement
  end

  defp replacement(%Mutant{mutated_source: mutated_source}) when is_binary(mutated_source) do
    mutated_source
  end

  defp replacement(%Mutant{mutated_ast: ast}), do: render_ast(ast)

  # M47: rendering one mutant's diff must never abort the whole report.
  # `Code.format_string!/1` re-parses `Macro.to_string/1`'s output, which
  # raises (e.g. TokenMissingError) for fragments that are not standalone-
  # parseable — heredoc-delimited literals (`delimiter: ~s(""")`) are the
  # known trigger. Degrade: fall back to the unformatted render, then to a
  # marker, rather than crashing after a full run.
  defp render_ast(ast) do
    ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  rescue
    _ -> unformatted_ast(ast)
  end

  defp unformatted_ast(ast) do
    Macro.to_string(ast)
  rescue
    exception -> "<replacement unavailable: #{inspect(exception.__struct__)}>"
  end

  defp location(%Mutant{span: {start_line, start_column, end_line, end_column}}) do
    %{
      "start" => %{"line" => start_line, "column" => column(start_column)},
      "end" => %{"line" => end_line || start_line, "column" => column(end_column || start_column)}
    }
  end

  defp location(%Mutant{line: line, column: column}) do
    point = %{"line" => line, "column" => column(column)}
    %{"start" => point, "end" => point}
  end

  defp column(nil), do: 0
  defp column(column), do: column

  defp status_reason(mutant, entry, status) when status in [:error, :invalid] do
    cond do
      not is_nil(mutant.compile_error) -> inspect(mutant.compile_error)
      not is_nil(Map.get(entry, :compile_error)) -> inspect(Map.fetch!(entry, :compile_error))
      not is_nil(Map.get(entry, :result)) -> Map.get(entry.result, :raw_output)
      true -> nil
    end
  end

  defp status_reason(mutant, _entry, :skipped), do: atom_string(mutant.skip_reason)
  defp status_reason(_mutant, _entry, _status), do: nil

  defp killed_by(%{killing_test: nil}), do: []
  defp killed_by(%{killing_test: killing_test}), do: [test_id(killing_test)]
  defp killed_by(_entry), do: []

  defp covered_by(%Mutant{covering_tests: nil}), do: []
  defp covered_by(%Mutant{covering_tests: tests}), do: Enum.map(tests, &test_id/1)

  defp duration(mutant, entry), do: Map.get(entry, :duration_ms) || mutant.duration_ms || 0

  defp test_id(test) when is_binary(test), do: String.replace(test, " ", ":", global: false)

  defp atom_string(nil), do: nil
  defp atom_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp ledger_mutant(%{mutant: %Mutant{} = mutant} = entry) do
    %{
      mutant
      | status: Map.get(entry, :status, mutant.status),
        killing_test: Map.get(entry, :killing_test, mutant.killing_test),
        duration_ms: Map.get(entry, :duration_ms, mutant.duration_ms)
    }
  end

  defp ledger_mutant(_entry), do: nil

  defp validate_schema_version(violations, %{"schemaVersion" => "2"}), do: violations

  defp validate_schema_version(violations, _rendered),
    do: ["schemaVersion must be \"2\"" | violations]

  defp validate_thresholds(violations, %{"thresholds" => %{"high" => high, "low" => low}})
       when is_number(high) and is_number(low),
       do: violations

  defp validate_thresholds(violations, _rendered) do
    ["thresholds.high and thresholds.low must be numeric" | violations]
  end

  defp validate_files(violations, %{"files" => files}) when is_map(files) do
    Enum.reduce(files, violations, fn {file, file_report}, acc ->
      validate_file(acc, file, file_report)
    end)
  end

  defp validate_files(violations, _rendered), do: ["files must be a map" | violations]

  defp validate_file(violations, file, %{
         "language" => language,
         "source" => source,
         "mutants" => mutants
       })
       when is_binary(language) and is_binary(source) and is_list(mutants) do
    mutants
    |> Enum.with_index()
    |> Enum.reduce(violations, fn {mutant, index}, acc ->
      validate_mutant(acc, file, index, mutant)
    end)
  end

  defp validate_file(violations, file, _file_report) do
    ["files.#{file} must include language, source, and mutants" | violations]
  end

  defp validate_mutant(violations, file, index, mutant) when is_map(mutant) do
    path = "files.#{file}.mutants[#{index}]"

    violations
    |> require_string(mutant, "id", path)
    |> require_string(mutant, "mutatorName", path)
    |> require_string(mutant, "replacement", path)
    |> require_status(mutant, path)
    |> require_location(mutant, path)
  end

  defp validate_mutant(violations, file, index, _mutant) do
    ["files.#{file}.mutants[#{index}] must be a map" | violations]
  end

  defp require_string(violations, mutant, key, path) do
    if is_binary(Map.get(mutant, key)),
      do: violations,
      else: ["#{path}.#{key} must be a string" | violations]
  end

  defp require_status(violations, mutant, path) do
    if Map.get(mutant, "status") in @valid_statuses do
      violations
    else
      ["#{path}.status must be one of #{inspect(@valid_statuses)}" | violations]
    end
  end

  defp require_location(violations, %{"location" => %{"start" => start, "end" => finish}}, path) do
    violations
    |> require_position(start, "#{path}.location.start")
    |> require_position(finish, "#{path}.location.end")
  end

  defp require_location(violations, _mutant, path),
    do: ["#{path}.location must include start and end" | violations]

  defp require_position(violations, %{"line" => line, "column" => column}, _path)
       when is_integer(line) and line > 0 and is_integer(column) and column >= 0,
       do: violations

  defp require_position(violations, _position, path) do
    ["#{path} must include positive integer line and non-negative integer column" | violations]
  end
end
