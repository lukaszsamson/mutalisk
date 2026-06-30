defmodule Mut.Reporter.Html do
  @moduledoc """
  M101: a self-contained HTML report of surviving mutants — the source line
  each survivor lives on plus the specific mutation (original → replacement) —
  so a team can act on them without a separate viewer.

  Opt-in (`--reporters html` / `config :mut, reporters: [...]`). Consumes the
  Stryker JSON map the tool already builds (shared file/line/mutation data);
  never recomputes a score or changes the default reporters. Output is a
  single static `.html` file (inline CSS, no assets).
  """

  @doc "Render a self-contained HTML report from the Stryker JSON map."
  @spec render(rendered :: map()) :: String.t()
  def render(rendered) when is_map(rendered) do
    files = Map.get(rendered, "files", %{})

    survivors_by_file =
      files
      |> Enum.map(fn {file, data} ->
        {file, Map.get(data, "source", ""),
         Enum.filter(Map.get(data, "mutants", []), &survivor?/1)}
      end)
      |> Enum.reject(fn {_file, _source, survivors} -> survivors == [] end)
      |> Enum.sort_by(fn {file, _source, _survivors} -> file end)

    total_survivors =
      survivors_by_file |> Enum.map(fn {_f, _s, m} -> length(m) end) |> Enum.sum()

    # A run whose mutants only errored (RuntimeError) or failed to compile
    # (CompileError) has zero survivors but is NOT clean — surface the
    # inconclusive count so an incomplete run is not presented as a pass
    # (Exploratory #34; adversarial: include CompileError too).
    inconclusive =
      files
      |> Enum.flat_map(fn {_file, data} -> Map.get(data, "mutants", []) end)
      |> Enum.count(&(Map.get(&1, "status") in ["RuntimeError", "CompileError"]))

    skipped =
      rendered
      |> get_in(["mutalisk", "metrics", "skipped"])
      |> skipped_count()

    total_mutants =
      files
      |> Enum.flat_map(fn {_file, data} -> Map.get(data, "mutants", []) end)
      |> length()

    score = score_summary(files, rendered)
    heading = heading(total_survivors, inconclusive, skipped, total_mutants)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>#{heading}</title>
    <style>#{css()}</style>
    </head>
    <body>
    <h1>#{heading}</h1>
    <p class="summary">#{score} #{total_survivors} surviving mutant#{plural(total_survivors)} across #{length(survivors_by_file)} file#{plural(length(survivors_by_file))}.#{inconclusive_note(inconclusive)}#{skipped_note(skipped)}</p>
    #{render_body(survivors_by_file, inconclusive, skipped, total_mutants)}
    </body>
    </html>
    """
  end

  defp inconclusive_note(0), do: ""
  defp inconclusive_note(n), do: " #{n} mutant#{plural(n)} errored or failed to compile."

  defp skipped_note(0), do: ""
  defp skipped_note(n), do: " #{n} candidate#{plural(n)} skipped."

  defp heading(_total_survivors, _inconclusive, skipped, 0) when skipped > 0,
    do: "Mutalisk — no scorable mutants"

  defp heading(_total_survivors, _inconclusive, _skipped, 0),
    do: "Mutalisk — no scorable mutants"

  defp heading(0, inconclusive, _skipped, _total_mutants) when inconclusive > 0,
    do: "Mutalisk — incomplete mutation run"

  defp heading(_total_survivors, _inconclusive, _skipped, _total_mutants),
    do: "Mutalisk — surviving mutants"

  # No survivors but inconclusive mutants present → incomplete, not clean.
  defp render_body([], inconclusive, _skipped, _total_mutants) when inconclusive > 0 do
    ~s(<p class="errored">No surviving mutants, but #{inconclusive} mutant#{plural(inconclusive)} errored or failed to compile — results are incomplete. See the terminal output or Stryker JSON for details.</p>)
  end

  defp render_body([], _inconclusive, skipped, 0) when skipped > 0 do
    ~s(<p class="errored">No scorable mutants were produced; #{skipped} candidate#{plural(skipped)} skipped. This is not a clean mutation pass.</p>)
  end

  defp render_body([], _inconclusive, _skipped, 0) do
    ~s(<p class="errored">No scorable mutants were produced. This is not a clean mutation pass.</p>)
  end

  defp render_body(survivors_by_file, _inconclusive, _skipped, _total_mutants),
    do: render_files(survivors_by_file)

  @doc "Render and write the HTML report to `path`."
  @spec write(rendered :: map(), path :: Path.t()) :: :ok
  def write(rendered, path) when is_map(rendered) and is_binary(path) do
    File.write!(path, render(rendered))
    :ok
  end

  defp survivor?(%{"status" => "Survived"}), do: true
  defp survivor?(%{"status" => "NoCoverage"}), do: true
  defp survivor?(_mutant), do: false

  defp skipped_count(nil), do: 0

  defp skipped_count(%{} = skipped) do
    skipped
    |> Map.values()
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp skipped_count(_other), do: 0

  defp score_summary(files, rendered) do
    statuses =
      files
      |> Enum.flat_map(fn {_file, data} -> Map.get(data, "mutants", []) end)
      |> Enum.frequencies_by(&Map.get(&1, "status"))

    detected = Map.get(statuses, "Killed", 0) + Map.get(statuses, "Timeout", 0)
    denominator = detected + Map.get(statuses, "Survived", 0) + Map.get(statuses, "NoCoverage", 0)
    threshold = get_in(rendered, ["thresholds", "high"])

    score =
      if denominator == 0 do
        "Mutation score: 0/0 (no scorable mutants)."
      else
        "Mutation score: #{detected}/#{denominator} = #{format_pct(detected / denominator * 100.0)}."
      end

    score <> threshold_note(threshold)
  end

  defp threshold_note(threshold) when is_number(threshold),
    do: " Threshold: #{format_pct(threshold)}."

  defp threshold_note(_threshold), do: ""

  defp format_pct(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 1) <> "%"

  defp render_files([]), do: ~s(<p class="clean">No surviving mutants. 🎉</p>)

  defp render_files(survivors_by_file) do
    Enum.map_join(survivors_by_file, "\n", fn {file, source, survivors} ->
      source_lines = String.split(source, "\n")

      """
      <section class="file">
      <h2>#{esc(file)}</h2>
      #{Enum.map_join(survivors, "\n", &render_mutant(&1, source_lines))}
      </section>
      """
    end)
  end

  defp render_mutant(mutant, source_lines) do
    %{line: line, column: col} = start_location(mutant)
    mutator = Map.get(mutant, "mutatorName", "Mutation")
    description = Map.get(mutant, "description", "")
    replacement = Map.get(mutant, "replacement", "")
    source_line = Enum.at(source_lines, line - 1, "")

    """
    <div class="mutant">
      <div class="loc">#{esc(mutator)} <span class="pos">#{line}:#{col}</span></div>
      <pre class="src"><span class="ln">#{line}</span>#{esc(source_line)}</pre>
      <div class="desc">#{esc(description)}</div>
      <div class="repl">replacement: <code>#{esc(replacement)}</code></div>
    </div>
    """
  end

  defp start_location(%{"location" => %{"start" => %{"line" => line} = start}}),
    do: %{line: line, column: Map.get(start, "column", 1)}

  defp start_location(_mutant), do: %{line: 1, column: 1}

  defp plural(1), do: ""
  defp plural(_n), do: "s"

  defp esc(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(value), do: value |> to_string() |> esc()

  defp css do
    """
    body{font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:2rem;color:#1a1a1a;background:#fafafa}
    h1{font-size:1.4rem}h2{font-size:1rem;margin:1.5rem 0 .5rem;color:#444}
    .summary{color:#666}.clean{color:#137333;font-size:1.1rem}.errored{color:#b06000;font-size:1.05rem}
    .file{margin-bottom:1.5rem}
    .mutant{border:1px solid #e0e0e0;border-left:4px solid #d93025;border-radius:4px;padding:.6rem .8rem;margin:.5rem 0;background:#fff}
    .loc{font-weight:600;color:#202124}.pos{color:#888;font-weight:400;margin-left:.4rem}
    .src{background:#f6f8fa;border-radius:3px;padding:.4rem .6rem;overflow-x:auto;margin:.4rem 0}
    .ln{display:inline-block;min-width:2.5rem;color:#999;user-select:none}
    .desc{color:#333}.repl{color:#555;margin-top:.2rem}
    code{background:#f0f0f0;padding:.1rem .3rem;border-radius:3px}
    """
  end
end
