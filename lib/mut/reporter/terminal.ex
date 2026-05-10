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
      concurrency_block(snapshot),
      test_timeout_block(snapshot),
      persistent_block(snapshot),
      persistent_warning(snapshot)
    ]
  end

  defp test_timeout_block(%Snapshot{test_timeout_ms: nil}), do: ""

  defp test_timeout_block(%Snapshot{test_timeout_ms: ms}) when is_integer(ms),
    do: "Test timeout: #{ms} ms\n"

  # M22 warning hint: emit a single line at run end if persistent
  # worker exceeded any threshold. Informational only — no
  # auto-fallback. First-tripped metric wins; the user looks at the
  # metrics block above for the full picture.
  defp persistent_warning(%Snapshot{persistent: nil}), do: ""

  defp persistent_warning(%Snapshot{persistent: p} = snapshot) do
    total_persistent = persistent_total_count(snapshot, p)
    fallback_total = engine_total(snapshot, :fallback)

    crash_rate = safe_rate(Map.get(p, :crash_count, 0), total_persistent)
    filter_miss_rate = safe_rate(Map.get(p, :filter_miss_count, 0), total_persistent)

    # M22 hint counts both compile and parse errors -- parse-class
    # in-process failures are also "the persistent worker disagreed
    # with mix-spawn" signals, even though they auto-recover via
    # mix-spawn fallback.
    compile_errors =
      snapshot.recompile_categories
      |> case do
        nil -> 0
        %{} = cats -> Map.get(cats, :compile_error, 0) + Map.get(cats, :parse_error, 0)
      end

    compile_error_rate = safe_rate(compile_errors, fallback_total)

    cond do
      crash_rate > 10.0 ->
        warning_line("crash rate", crash_rate)

      filter_miss_rate > 25.0 ->
        warning_line("filter-miss rate", filter_miss_rate)

      compile_error_rate > 5.0 ->
        warning_line("in-process fallback compile-error rate", compile_error_rate)

      true ->
        ""
    end
  end

  defp persistent_total_count(snapshot, persistent_block) do
    schema = engine_total(snapshot, :schema)
    fallback = engine_total(snapshot, :fallback)

    case schema + fallback do
      0 -> Map.get(persistent_block, :mix_fallback_count, 0)
      n -> n
    end
  end

  defp safe_rate(_count, 0), do: 0.0
  defp safe_rate(count, total), do: count / total * 100.0

  defp warning_line(metric, rate) do
    "\nHint: persistent worker had high #{metric} (#{format_pct(rate)}). Consider --worker-type mix.\n"
  end

  defp persistent_block(%Snapshot{persistent: nil}), do: ""

  defp persistent_block(%Snapshot{persistent: p} = snapshot) do
    boot = Map.get(p, :boot_ms, %{})
    app = Map.get(p, :app_startup_ms, %{})
    test_load = Map.get(p, :test_load_ms, %{})
    run = Map.get(p, :mutant_run_ms, %{})
    reset = Map.get(p, :reset_ms, %{})
    memory = Map.get(p, :memory, %{})

    [
      "\nPersistent worker:\n",
      "  workers:     #{Map.get(p, :worker_count, 0)}\n",
      "  boot:        median #{format_ms(Map.get(boot, :median, 0))} (max #{format_ms(Map.get(boot, :max, 0))})\n",
      "  app startup: median #{format_ms(Map.get(app, :median, 0))} (total apps: #{Map.get(app, :total_apps, 0)})\n",
      "  test load:   median #{format_ms(Map.get(test_load, :median, 0))} (total files: #{Map.get(test_load, :total_files, 0)})\n",
      "  mutant run:  median #{format_ms(Map.get(run, :median, 0))} (p95 #{format_ms(Map.get(run, :p95, 0))}, n=#{Map.get(run, :count, 0)})\n",
      "  reset hooks:\n",
      "    application_env: #{format_ms(Map.get(reset, :application_env, 0))}\n",
      "    ets:             #{format_ms(Map.get(reset, :ets, 0))}\n",
      "    processes:       #{format_ms(Map.get(reset, :processes, 0))}\n",
      "    persistent_term: #{format_ms(Map.get(reset, :persistent_term, 0))}\n",
      "    on_exit:         #{format_ms(Map.get(reset, :on_exit, 0))}\n",
      "    mox:             #{format_ms(Map.get(reset, :mox, 0))}\n",
      "    ecto:            #{format_ms(Map.get(reset, :ecto, 0))}\n",
      "  filter lookup: #{format_ms(Map.get(p, :filter_lookup_ms, 0))}\n",
      operational_counters_line(p, snapshot),
      "  memory: peak #{format_mb(Map.get(memory, :peak_total_mb, 0.0))} total, #{format_mb(Map.get(memory, :peak_processes_mb, 0.0))} processes\n"
    ]
  end

  # M22: surface operational counters. Compile errors come from the
  # snapshot-wide recompile_categories (set by in-process fallback path).
  # Omit the line entirely when all five are zero — boring is the
  # signal we want.
  defp operational_counters_line(p, snapshot) do
    crashes = Map.get(p, :crash_count, 0)
    restarts = Map.get(p, :restart_count, 0)
    filter_miss = Map.get(p, :filter_miss_count, 0)
    mix_fallback = Map.get(p, :mix_fallback_count, 0)

    {compile_errors, parse_errors} =
      case snapshot.recompile_categories do
        nil -> {0, 0}
        %{} = cats -> {Map.get(cats, :compile_error, 0), Map.get(cats, :parse_error, 0)}
      end

    if crashes + restarts + filter_miss + mix_fallback + compile_errors + parse_errors == 0 do
      ""
    else
      "  crashes: #{crashes}  restarts: #{restarts}  filter-miss: #{filter_miss}  in-process compile errors: #{compile_errors}  parse errors: #{parse_errors}  mix fallbacks: #{mix_fallback}\n"
    end
  end

  defp format_ms(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 1) <> " ms"

  defp format_ms(_), do: "0.0 ms"

  defp format_mb(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 1) <> " MB"

  defp format_mb(_), do: "0.0 MB"

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
