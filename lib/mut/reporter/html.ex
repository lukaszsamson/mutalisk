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

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Mutalisk — surviving mutants</title>
    <style>#{css()}</style>
    </head>
    <body>
    <h1>Mutalisk — surviving mutants</h1>
    <p class="summary">#{total_survivors} surviving mutant#{plural(total_survivors)} across #{length(survivors_by_file)} file#{plural(length(survivors_by_file))}.</p>
    #{render_files(survivors_by_file)}
    </body>
    </html>
    """
  end

  @doc "Render and write the HTML report to `path`."
  @spec write(rendered :: map(), path :: Path.t()) :: :ok
  def write(rendered, path) when is_map(rendered) and is_binary(path) do
    File.write!(path, render(rendered))
    :ok
  end

  defp survivor?(%{"status" => "Survived"}), do: true
  defp survivor?(%{"status" => "NoCoverage"}), do: true
  defp survivor?(_mutant), do: false

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
    .summary{color:#666}.clean{color:#137333;font-size:1.1rem}
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
