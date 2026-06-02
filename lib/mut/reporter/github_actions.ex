defmodule Mut.Reporter.GitHubActions do
  @moduledoc """
  M101: emit GitHub Actions workflow `::warning` commands for surviving
  mutants, so they appear as inline annotations on the PR's changed files.

  Opt-in (`--reporters github_actions` / `config :mut, reporters: [...]`).
  Consumes the Stryker JSON map the tool already builds, so it shares the
  file/line/mutation data with the other reporters and never recomputes a
  score or changes the default reporters.

  One annotation per surviving mutant:

      ::warning file=lib/foo.ex,line=12,col=7::Mutalisk: surviving mutant \
      [ComparisonBoundary] replace < with <= — replacement: `a <= b`

  Message text is escaped per the workflow-command spec (`%`/CR/LF), and
  property values (file/line/col) carry no special characters.
  """

  @doc """
  Render the `::warning` command lines for every surviving mutant in the
  Stryker JSON map. Returns a list of strings (one per survivor); empty when
  there are no survivors.
  """
  @spec render(rendered :: map()) :: [String.t()]
  def render(rendered) when is_map(rendered) do
    rendered
    |> Map.get("files", %{})
    |> Enum.sort_by(fn {file, _data} -> file end)
    |> Enum.flat_map(fn {file, data} ->
      data
      |> Map.get("mutants", [])
      |> Enum.filter(&survivor?/1)
      |> Enum.map(&annotation(file, &1))
    end)
  end

  @doc "Render and print the annotations to stdout (where Actions captures them)."
  @spec emit(rendered :: map()) :: :ok
  def emit(rendered) when is_map(rendered) do
    rendered |> render() |> Enum.each(&IO.puts/1)
  end

  defp survivor?(%{"status" => "Survived"}), do: true
  defp survivor?(%{"status" => "NoCoverage"}), do: true
  defp survivor?(_mutant), do: false

  defp annotation(file, mutant) do
    %{"line" => line, "column" => col} = start_location(mutant)
    mutator = Map.get(mutant, "mutatorName", "Mutation")
    description = Map.get(mutant, "description", "")
    replacement = Map.get(mutant, "replacement", "")

    message =
      "Mutalisk: surviving mutant [#{mutator}] #{description} — replacement: `#{replacement}`"

    "::warning file=#{file},line=#{line},col=#{col}::#{escape(message)}"
  end

  defp start_location(mutant) do
    case mutant do
      %{"location" => %{"start" => %{"line" => line} = start}} ->
        %{"line" => line, "column" => Map.get(start, "column", 1)}

      _ ->
        %{"line" => 1, "column" => 1}
    end
  end

  # Workflow-command message escaping (GitHub spec): %, CR, LF.
  defp escape(message) do
    message
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end
end
