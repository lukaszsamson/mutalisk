defmodule Mut.Reporter.Terminal do
  @moduledoc "Renders mutation progress and terminal summaries."

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Worker.Result

  @status_colors %{
    killed: :green,
    survived: :red,
    timeout: :yellow,
    error: :magenta,
    invalid: :magenta,
    skipped: :light_black
  }

  @spec stream_event(Snapshot.t(), Mutant.t(), Result.t()) :: :ok
  def stream_event(%Snapshot{} = snapshot, %Mutant{} = mutant, %Result{} = result) do
    index = Enum.count(snapshot.ledger, &executed?/1)
    status = Atom.to_string(result.status)

    line =
      [
        "[#{index}/#{planned_total(snapshot)}] ",
        color(result.status, String.pad_trailing(status, 8)),
        "  ",
        location(mutant),
        "  ",
        mutant.mutator_name,
        "  ",
        mutant.description,
        "\n"
      ]

    IO.write(line)
  end

  @spec render_summary(Snapshot.t()) :: iodata()
  def render_summary(%Snapshot{} = snapshot) do
    killed = status_count(snapshot, :killed)
    survived = status_count(snapshot, :survived)
    denominator = killed + survived
    denominator = if denominator == 0, do: 0, else: denominator

    [
      "Mutation score: #{killed}/#{denominator} = #{format_pct(snapshot.score)}\n\n",
      surviving_block(snapshot),
      "\n",
      engine_line(snapshot, :schema, "Schema:   "),
      "\n",
      engine_line(snapshot, :fallback, "Fallback: "),
      fallback_kind_lines(snapshot),
      recompile_categories_block(snapshot),
      "\n",
      count_line(
        "Skipped",
        status_count(snapshot, :skipped),
        grouped(snapshot.skipped_by_reason)
      ),
      "\n",
      count_line(
        "Invalid",
        status_count(snapshot, :invalid),
        grouped(snapshot.invalid_by_mutator)
      ),
      "\n",
      count_line("Errors", status_count(snapshot, :error), ""),
      "\n",
      count_line("Timeouts", status_count(snapshot, :timeout), ""),
      "\n\n",
      "Run time: #{format_seconds(snapshot.wall_clock_ms.total)}\n",
      "Fallback wall-clock: #{fallback_wall_pct(snapshot)} of total\n",
      "Fallback mutants: #{fallback_count_pct(snapshot)} of executed\n",
      phase_block(snapshot),
      selection_block(snapshot),
      concurrency_block(snapshot)
    ]
  end

  defp recompile_categories_block(%Snapshot{recompile_categories: nil}), do: ""

  defp recompile_categories_block(%Snapshot{recompile_categories: cats}) do
    total = Enum.sum(Map.values(cats))

    if total == 0 do
      ""
    else
      compile_n = Map.get(cats, :compile_error, 0)
      dep_n = Map.get(cats, :dep_path_error, 0)
      unknown_n = Map.get(cats, :unknown, 0)

      "  recompile errors:\n" <>
        "    compile errors:    #{compile_n}\n" <>
        "    dep path errors:   #{dep_n}\n" <>
        "    unknown:           #{unknown_n}\n"
    end
  end

  defp concurrency_block(%Snapshot{concurrency: nil}), do: ""

  defp concurrency_block(%Snapshot{concurrency: c}) do
    suffix =
      cond do
        c.configured > c.schedulers_online ->
          " (capped at #{c.schedulers_online} schedulers_online)"

        c.configured == 1 ->
          " (sequential)"

        true ->
          ""
      end

    "\nConcurrency: #{c.effective} workers#{suffix}\n"
  end

  defp surviving_block(snapshot) do
    survivors = Enum.filter(snapshot.ledger, &(&1.status == :survived))

    if survivors == [] do
      "Surviving mutants:\n  none\n"
    else
      [
        "Surviving mutants:\n",
        Enum.map(survivors, fn entry ->
          mutant = entry.mutant

          "  #{String.pad_trailing(location(mutant), 13)} #{String.pad_trailing(mutant.mutator_name, 24)} #{mutant.description}\n"
        end)
      ]
    end
  end

  defp planned_total(%Snapshot{planned_total: total}) when is_integer(total), do: total
  defp planned_total(%Snapshot{total: total}), do: total

  defp executed?(%{status: status}), do: status not in [:skipped, :invalid]

  defp engine_line(snapshot, engine, label) do
    total = engine_total(snapshot, engine)
    killed = Map.get(snapshot.by_engine_status, {engine, :killed}, 0)
    score = if total == 0, do: 100.0, else: killed / total * 100.0
    wall_ms = Map.get(snapshot.wall_clock_ms, engine, 0)

    "#{label} #{killed}/#{total} killed (#{format_pct(score)})   wall: #{format_seconds(wall_ms)}"
  end

  defp fallback_kind_lines(snapshot) do
    snapshot.ledger
    |> Enum.filter(&(&1.engine == :fallback))
    |> Enum.group_by(& &1.mutation_kind)
    |> Enum.sort_by(fn {kind, _entries} -> Atom.to_string(kind || :unknown) end)
    |> Enum.map(fn {kind, entries} ->
      total = length(entries)
      killed = Enum.count(entries, &(&1.status == :killed))

      "\n  #{String.pad_trailing(Atom.to_string(kind || :unknown) <> ":", 29)} #{killed}/#{total} killed"
    end)
  end

  defp count_line(label, count, suffix) do
    "#{String.pad_trailing(label <> ":", 10)} #{count}#{suffix}"
  end

  defp grouped(map) when map == %{}, do: ""

  defp grouped(map) do
    rendered =
      map
      |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
      |> Enum.map_join(", ", fn {key, value} -> "#{group_key(key)}: #{value}" end)

    " (#{rendered})"
  end

  defp group_key(key) when is_atom(key), do: Atom.to_string(key)
  defp group_key(key) when is_binary(key), do: key
  defp group_key(key), do: inspect(key)

  defp engine_total(snapshot, engine) do
    snapshot.by_engine_status
    |> Enum.filter(fn {{entry_engine, _status}, _count} -> entry_engine == engine end)
    |> Enum.reduce(0, fn {_key, count}, total -> total + count end)
  end

  defp status_count(snapshot, status), do: Map.get(snapshot.by_status, status, 0)

  defp fallback_wall_pct(%Snapshot{wall_clock_ms: %{fallback: fallback, total: total}})
       when total > 0 do
    format_pct(fallback / total * 100.0)
  end

  defp fallback_wall_pct(_snapshot), do: "0.0%"

  defp fallback_count_pct(%Snapshot{fallback_count_pct: pct}) when is_number(pct),
    do: format_pct(pct)

  defp fallback_count_pct(snapshot) do
    schema = engine_total(snapshot, :schema)
    fallback = engine_total(snapshot, :fallback)

    case schema + fallback do
      0 -> "0.0%"
      total -> format_pct(fallback / total * 100.0)
    end
  end

  defp phase_block(%Snapshot{phase_timings: nil}), do: ""

  defp phase_block(%Snapshot{phase_timings: timings}) do
    phases = [
      {:oracle_build_ms, "oracle build"},
      {:baseline_tests_ms, "baseline tests"},
      {:plan_generation_ms, "plan generation"},
      {:coverage_collection_ms, "coverage collection"},
      {:schema_build_ms, "schema build"},
      {:schema_workers_ms, "schema workers"},
      {:fallback_workers_ms, "fallback workers"},
      {:report_writing_ms, "report writing"},
      {:total_ms, "total"}
    ]

    rows =
      phases
      |> Enum.map(fn {key, label} -> {label, Map.get(timings, key, 0)} end)
      |> Enum.reject(fn {label, value} -> value == 0 and label != "total" end)

    if rows == [] do
      ""
    else
      width =
        rows
        |> Enum.map(fn {_label, value} -> value |> Integer.to_string() |> String.length() end)
        |> Enum.max()

      [
        "\nPhases:\n",
        Enum.map(rows, fn {label, value} ->
          "  #{String.pad_trailing(label <> ":", 20)} #{String.pad_leading(Integer.to_string(value), width)} ms\n"
        end)
      ]
    end
  end

  defp selection_block(%Snapshot{selection: nil}), do: ""

  defp selection_block(%Snapshot{selection: selection}) do
    distribution = Map.get(selection, :coverage_match_distribution, %{})

    [
      "\nSelection:\n",
      "  mode: #{selection.mode}\n",
      "  match distribution:\n",
      "    exact line:         #{Map.get(distribution, :exact_line, 0)}\n",
      "    enclosing function: #{Map.get(distribution, :enclosing_function, 0)}\n",
      "    static fallback:    #{Map.get(distribution, :static_fallback, 0)}\n",
      "    all tests:          #{Map.get(distribution, :all_tests, 0)}\n",
      "  avg tests/mutant: #{format_float(Map.get(selection, :selected_tests_avg, 0.0))}\n",
      "  median tests/mutant: #{Map.get(selection, :selected_tests_median, 0)}\n",
      "  coverage collection: #{Map.get(selection, :coverage_collection_wall_ms, 0)} ms\n"
    ]
  end

  defp format_seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  defp format_pct(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"
  defp format_float(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp location(%Mutant{file: file, line: line}), do: "#{file}:#{line}"

  defp color(status, text) do
    if colors?() and Map.has_key?(@status_colors, status) do
      [apply(IO.ANSI, Map.fetch!(@status_colors, status), []), text, IO.ANSI.reset()]
    else
      text
    end
  end

  defp colors? do
    if System.get_env("NO_COLOR"), do: false, else: IO.ANSI.enabled?()
  end
end
