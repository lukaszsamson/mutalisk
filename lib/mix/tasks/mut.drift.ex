defmodule Mix.Tasks.Mut.Drift do
  @shortdoc "Auto-classify mix-vs-persistent stable-id drift across bench results"
  @moduledoc """
  Drift-bucketing analysis tool.

  Consumes `bench/results/<target>.<...>.stryker.json` pairs (one
  mix-mode, one persistent-mode) and produces a per-target table
  classifying drifting mutants by heuristic. See
  `Mut.Drift.Bucketer` for the heuristic catalogue.

  ## Usage

      mix mut.drift --target nimble_options
      mix mut.drift --all
      mix mut.drift --all --results-dir bench/results

  ## Options

    --target NAME       One of the bench targets (e.g. `mox`, `ecto`,
                        `nimble_options`). Reads
                        `bench/results/NAME.*.stryker.json` and
                        `bench/results/NAME.*.persistent.stryker.json`.
    --all               Analyse every target with both a mix and
                        persistent report present in the results
                        directory.
    --results-dir DIR   Override the default `bench/results`.
    --suffix S          Restrict matching to a specific filename suffix
                        (e.g. `static.c4` or `static.c4.body_literal`).
                        Default: pick the report pair with the most
                        common suffix (typically `static.c4`).

  Exit status is 0 when at least one target was analysed; 1 if no
  pairs were found (e.g. `--target` mistyped).
  """

  use Mix.Task

  alias Mut.Drift.Bucketer
  alias Mut.Drift.Bucketer.Result

  @default_results_dir "bench/results"

  @switches [
    target: :string,
    all: :boolean,
    results_dir: :string,
    suffix: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    results_dir = Keyword.get(opts, :results_dir, @default_results_dir)

    cond do
      Keyword.get(opts, :all) ->
        analyse_all(results_dir, opts)

      target = Keyword.get(opts, :target) ->
        analyse_one(results_dir, target, opts)

      true ->
        Mix.shell().error("mix mut.drift: pass --target NAME or --all")
        exit({:shutdown, 64})
    end
  end

  defp analyse_all(results_dir, opts) do
    pairs = discover_pairs(results_dir, Keyword.get(opts, :suffix))

    if pairs == [] do
      Mix.shell().error("mix mut.drift: no mix/persistent report pairs in #{results_dir}")
      exit({:shutdown, 1})
    end

    pairs
    |> Enum.sort_by(fn {target, _, _} -> target end)
    |> Enum.each(fn {target, mix_path, persistent_path} ->
      result = analyse_pair(target, mix_path, persistent_path)
      print_table(result)
      IO.puts("")
    end)
  end

  defp analyse_one(results_dir, target, opts) do
    case find_pair(results_dir, target, Keyword.get(opts, :suffix)) do
      {mix_path, persistent_path} ->
        result = analyse_pair(target, mix_path, persistent_path)
        print_table(result)

      :error ->
        Mix.shell().error(
          "mix mut.drift: no mix+persistent report pair for target #{target} in #{results_dir}"
        )

        exit({:shutdown, 1})
    end
  end

  defp analyse_pair(target, mix_path, persistent_path) do
    mix_report = mix_path |> File.read!() |> Mut.JSON.decode!()
    persistent_report = persistent_path |> File.read!() |> Mut.JSON.decode!()
    Bucketer.analyze(mix_report, persistent_report, target)
  end

  ## ---- discovery ---------------------------------------------------------

  @doc false
  def discover_pairs(results_dir, suffix) do
    files = Path.wildcard(Path.join(results_dir, "*.stryker.json"))

    files
    |> Enum.group_by(&extract_target/1)
    |> Enum.flat_map(fn {target, paths} ->
      case pair_for_paths(paths, suffix) do
        {mix, persistent} -> [{target, mix, persistent}]
        :error -> []
      end
    end)
  end

  defp find_pair(results_dir, target, suffix) do
    paths = Path.wildcard(Path.join(results_dir, "#{target}.*.stryker.json"))
    pair_for_paths(paths, suffix)
  end

  # Group report paths into mix vs persistent partitions and return
  # the most representative pair. Filename convention from M25/M27:
  #   <target>.<selection>[.cN][.persistent][.body_literal].stryker.json
  # The pair we want is the matching pair (same suffix mod
  # `.persistent.`). Default is the suffix with the most reports
  # (favours `static.c4`).
  defp pair_for_paths(paths, requested_suffix) do
    {mixes, persistents} =
      paths
      |> Enum.split_with(fn path ->
        not String.contains?(Path.basename(path), ".persistent.")
      end)

    mix_by_key = Map.new(mixes, &{key_for(&1), &1})
    persistent_by_key = Map.new(persistents, &{key_for(&1), &1})

    candidates =
      mix_by_key
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(persistent_by_key, &1))

    candidates =
      case requested_suffix do
        nil -> candidates
        suffix -> Enum.filter(candidates, &(&1 == suffix))
      end

    # Prefer the shortest matching key. With M25/M27's filename
    # convention, `static.c4` < `static.c4.body_literal`, so the
    # default pair is the baseline matrix run rather than the
    # body-literal opt-in. Use `--suffix` to override.
    sorted = Enum.sort_by(candidates, &{String.length(&1), &1})

    case sorted do
      [] -> :error
      [best | _] -> {Map.fetch!(mix_by_key, best), Map.fetch!(persistent_by_key, best)}
    end
  end

  # Strip the leading `<target>.` and trailing `.stryker.json`,
  # then strip the `.persistent` segment if present. Whatever
  # remains is the suffix used to pair mix vs persistent reports.
  defp key_for(path) do
    base = Path.basename(path, ".stryker.json")

    case String.split(base, ".", parts: 2) do
      [_target] -> ""
      [_target, rest] -> String.replace(rest, ".persistent", "")
    end
  end

  defp extract_target(path) do
    base = Path.basename(path, ".stryker.json")
    [target | _] = String.split(base, ".", parts: 2)
    target
  end

  ## ---- formatting --------------------------------------------------------

  defp print_table(%Result{} = result) do
    total = Result.total(result)
    drift = Result.drift_total(result)
    drift_pct = Result.drift_rate(result)
    unclassified_pct = Result.unclassified_rate(result)

    target = result.target || "(unknown)"

    IO.puts("Target: #{target}")
    IO.puts("─────────────────────────────")
    IO.puts(pad("Total mutants:", "#{total}"))

    agree_killed = length(result.agree_killed)
    agree_survived = length(result.agree_survived)
    agree_other = Enum.sum(Map.values(result.agree_other))
    agree_total = agree_killed + agree_survived + agree_other

    IO.puts(
      pad(
        "Agree killed/survived:",
        "#{agree_killed} / #{agree_survived}#{maybe_other(agree_other)}  (#{pct(agree_total, total)})"
      )
    )

    IO.puts(pad("Drift:", "#{drift}  (#{drift_pct}%)"))

    Enum.each(Bucketer.drift_buckets(), fn bucket ->
      label = "  #{bucket}:"
      count = Map.get(result.buckets, bucket, 0)
      IO.puts(pad(label, "#{count}"))
    end)

    if result.mix_only != [] or result.persistent_only != [] do
      IO.puts(pad("Mix-only ids:", "#{length(result.mix_only)}"))
      IO.puts(pad("Persistent-only ids:", "#{length(result.persistent_only)}"))
    end

    IO.puts(pad("Unclassified rate (of drift):", "#{unclassified_pct}%"))
  end

  defp maybe_other(0), do: ""
  defp maybe_other(n), do: " (+#{n} other)"

  defp pct(_, 0), do: "0%"

  defp pct(n, total) do
    "#{Float.round(n / total * 100, 1)}%"
  end

  defp pad(label, value) do
    label = String.pad_trailing(label, 32)
    "#{label}#{value}"
  end
end
