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
        "[#{index}/#{progress_total(snapshot)}] ",
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
    timeout = status_count(snapshot, :timeout)
    # Timeouts are detections (see Mut.Metrics score/3), so the displayed
    # fraction is detected/total = (killed + timeout) / (killed + timeout +
    # survived) — consistent with snapshot.score and the Stryker HTML viewer.
    detected = killed + timeout
    denominator = detected + survived

    [
      score_line(detected, denominator, snapshot.score),
      surviving_block(snapshot),
      errored_block(snapshot),
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
      "\n",
      count_line("No coverage", status_count(snapshot, :no_coverage), ""),
      "\n\n",
      "Mutant execution time: #{format_seconds(snapshot.wall_clock_ms.total)}\n",
      "Fallback wall-clock: #{fallback_wall_pct(snapshot)} of total\n",
      "Fallback mutants: #{fallback_count_pct(snapshot)} of executed\n",
      phase_block(snapshot),
      selection_block(snapshot),
      concurrency_block(snapshot),
      test_timeout_block(snapshot),
      incremental_block(snapshot)
    ]
  end

  # M106: only shown for `--incremental` runs that actually reused something.
  defp incremental_block(%Snapshot{reused: reused}) when is_integer(reused) and reused > 0,
    do: "Incremental: #{reused} reused from history\n"

  defp incremental_block(_snapshot), do: ""

  defp test_timeout_block(%Snapshot{test_timeout_ms: nil}), do: ""

  defp test_timeout_block(%Snapshot{test_timeout_ms: ms}) when is_integer(ms),
    do: "Test timeout: #{ms} ms\n"

  defp recompile_categories_block(%Snapshot{recompile_categories: nil}), do: ""

  defp recompile_categories_block(%Snapshot{recompile_categories: cats}) do
    total = Enum.sum(Map.values(cats))

    if total == 0 do
      ""
    else
      compile_n = Map.get(cats, :compile_error, 0)
      parse_n = Map.get(cats, :parse_error, 0)
      dep_n = Map.get(cats, :dep_path_error, 0)
      unknown_n = Map.get(cats, :unknown, 0)

      "  recompile errors:\n" <>
        "    compile errors:    #{compile_n}\n" <>
        "    parse errors:      #{parse_n}\n" <>
        "    dep path errors:   #{dep_n}\n" <>
        "    unknown:           #{unknown_n}\n"
    end
  end

  defp concurrency_block(%Snapshot{concurrency: nil}), do: ""

  defp concurrency_block(%Snapshot{concurrency: c}) do
    suffix =
      cond do
        # Effective < configured: the pool was capped to the mutant count (no
        # point in more workers than mutants).
        c.effective < c.configured ->
          " (#{c.configured} requested, capped to #{c.effective} — no more workers than mutants)"

        c.effective == 1 ->
          " (sequential)"

        # Oversubscribed past CPU count but NOT capped — say so without the
        # misleading word "capped" (Exploratory #58).
        c.effective > c.schedulers_online ->
          " (above #{c.schedulers_online} schedulers_online)"

        true ->
          ""
      end

    "\nConcurrency: #{c.effective} workers#{suffix}\n"
  end

  # A run with no scorable mutants (denominator 0) has no meaningful score: the
  # underlying `score/3` returns 100.0 as a neutral default, but printing
  # "0/0 = 100.0%" reads as a passing run when nothing was scored. Surface it
  # explicitly instead. "Scorable" rather than "evaluated" because errored /
  # invalid / skipped mutants may still be present (and listed below) — they just
  # don't contribute to the score. (Exploratory issue #4.)
  defp score_line(_detected, 0, _score),
    do: "Mutation score: 0/0 (no scorable mutants)\n\n"

  defp score_line(detected, denominator, score),
    do: "Mutation score: #{detected}/#{denominator} = #{format_pct(score)}\n\n"

  # Errored mutants carry an actionable reason (compile error or test output) in
  # the ledger; the headline only counts them. Surface a concise, single-line
  # reason here so users don't have to open the JSON report. (Exploratory #6.)
  defp errored_block(snapshot) do
    errored = Enum.filter(snapshot.ledger, &(&1.status == :error))

    if errored == [] do
      ""
    else
      [
        "\nErrored mutants:\n",
        Enum.map(errored, fn entry ->
          mutant = entry.mutant

          "  #{String.pad_trailing(location(mutant), 16)} #{String.pad_trailing(mutant.mutator_name, 24)} #{error_reason(entry)}\n"
        end)
      ]
    end
  end

  defp error_reason(entry) do
    reason =
      cond do
        not is_nil(Map.get(entry.mutant, :compile_error)) ->
          inspect(entry.mutant.compile_error)

        match?(%{raw_output: out} when is_binary(out), Map.get(entry, :result)) ->
          entry.result.raw_output

        true ->
          "(see stryker.report.json for the full reason)"
      end

    reason
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> truncate(100)
  end

  # Codepoint-based slice so truncation never splits a multibyte UTF-8 char.
  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
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

          "  #{String.pad_trailing(location(mutant), 16)} #{String.pad_trailing(mutant.mutator_name, 24)} #{mutant.description}\n"
        end)
      ]
    end
  end

  defp planned_total(%Snapshot{planned_total: total}) when is_integer(total), do: total
  defp planned_total(%Snapshot{total: total}), do: total

  # T12: under `--incremental`, reused verdicts are recorded in the ledger
  # before execution, so the streamed `index` (executed-status ledger count)
  # includes them. `planned_total` counts only the to-execute subset, so the
  # progress denominator must add the reused count back or `index` overshoots
  # it (the reported `[37/30]`).
  defp progress_total(%Snapshot{reused: reused} = snapshot) when is_integer(reused),
    do: planned_total(snapshot) + reused

  defp progress_total(snapshot), do: planned_total(snapshot)

  defp executed?(%{status: status}), do: status not in [:skipped, :invalid, :no_coverage]

  defp engine_line(snapshot, engine, label) do
    # Use the SAME score arithmetic as the headline mutation score: detected
    # (killed + timeout) over scored (detected + survived). The old `killed /
    # engine_total` counted :invalid/:error in the denominator and dropped
    # :timeout from the numerator, so per-engine lines disagreed with the total.
    killed = engine_status_count(snapshot, engine, :killed)
    timeout = engine_status_count(snapshot, engine, :timeout)
    survived = engine_status_count(snapshot, engine, :survived)
    detected = killed + timeout
    scored = detected + survived
    score = if scored == 0, do: 100.0, else: detected / scored * 100.0
    wall_ms = Map.get(snapshot.wall_clock_ms, engine, 0)

    "#{label} #{detected}/#{scored} detected (#{format_pct(score)})   wall: #{format_seconds(wall_ms)}"
  end

  defp engine_status_count(snapshot, engine, status),
    do: Map.get(snapshot.by_engine_status, {engine, status}, 0)

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

  # Include the column when known: same-line mutants (e.g. two operators on one
  # line) are otherwise indistinguishable in terminal rows. (Exploratory #5.)
  defp location(%Mutant{file: file, line: line, column: column}) when is_integer(column),
    do: "#{file}:#{line}:#{column}"

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
