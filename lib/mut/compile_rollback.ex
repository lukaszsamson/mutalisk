defmodule Mut.CompileRollback do
  @moduledoc "Recovers schema builds by invalidating non-compiling mutants."

  alias Mut.Plan
  alias Mut.SchemaPlacer.PlacementMap

  @anchor ~r/(?<![\w.\/-])(?<file>(?:\.\.?\/)?[^\s:]+\.exs?):(?<line>\d+)(?::\d+)?/
  @compile_args ["compile", "--force"]

  @type anchor :: %{file: Path.t(), line: pos_integer(), diagnostic: String.t()}
  @type invalidation :: %{
          mutant_id: non_neg_integer(),
          file: Path.t(),
          line: pos_integer() | nil,
          diagnostic: String.t()
        }

  @spec run(Path.t(), Plan.t(), %{Path.t() => PlacementMap.t()}, keyword) ::
          {:ok,
           %{
             plan: Plan.t(),
             placement_maps: %{Path.t() => PlacementMap.t()},
             invalid_mutants: [invalidation],
             rollback_iterations: non_neg_integer()
           }}
          | {:error, term}
  def run(work_copy_root, %Plan{} = plan, placement_maps, opts) do
    state = %{
      work_copy_root: work_copy_root,
      plan: plan,
      placement_maps: placement_maps,
      invalid_mutants: [],
      invalid_by_file: initial_invalid_by_file(plan),
      iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, 3),
      max_invalid_per_file: Keyword.get(opts, :max_invalid_per_file),
      env: Keyword.fetch!(opts, :env),
      compile_args: Keyword.get(opts, :compile_args, @compile_args),
      original_sources: Keyword.get(opts, :original_sources, %{})
    }

    loop(state, Keyword.fetch!(opts, :initial_output), 1)
  end

  @spec diagnostic_anchors(String.t()) :: [anchor]
  def diagnostic_anchors(output) do
    # R10: anchor ONLY on error diagnostics, not warnings. The rollback
    # invalidates the mutants on each anchored line; a mutant whose instrumented
    # line merely emitted a *warning* (while a DIFFERENT mutant caused the actual
    # compile error) must not be invalidated. Elixir groups diagnostics under a
    # `warning:`/`error:` header and prints the `file:line` on a following line,
    # so we carry the current severity as we scan and keep only error anchors.
    output
    |> String.split("\n")
    |> Enum.reduce({:error, []}, fn line, {severity, acc} ->
      severity = severity_for(line, severity)
      {severity, acc ++ error_anchors(line, severity)}
    end)
    |> elem(1)
    |> Enum.uniq_by(&{&1.file, &1.line, &1.diagnostic})
  end

  defp error_anchors(_line, :warning), do: []

  defp error_anchors(line, :error) do
    @anchor
    |> Regex.scan(line, capture: :all_names)
    |> Enum.map(fn [file, line_number] ->
      %{file: normalize_file(file), line: String.to_integer(line_number), diagnostic: line}
    end)
  end

  # Track the severity of the current diagnostic block. A `warning:` header
  # opens a warning region (its `file:line` lines are ignored for rollback); an
  # `error:` header or an `** (…Error)` exception line opens an error region.
  defp severity_for(line, current) do
    cond do
      Regex.match?(~r/(^|\s)warning:/, line) -> :warning
      Regex.match?(~r/(^|\s)error:/, line) -> :error
      String.contains?(line, "** (") -> :error
      true -> current
    end
  end

  @spec locate_mutants(PlacementMap.t(), pos_integer) :: {:ok, [non_neg_integer()]} | :not_found
  def locate_mutants(%PlacementMap{entries: entries}, line) do
    entries
    |> Enum.filter(&(line >= &1.start_line and line <= &1.end_line))
    |> Enum.sort_by(&{&1.end_line - &1.start_line, length(&1.mut_ids)})
    |> case do
      [entry | _rest] -> {:ok, entry.mut_ids}
      [] -> :not_found
    end
  end

  defp loop(state, _output, 0), do: success(state)

  defp loop(%{iteration: iteration, max_iterations: max_iterations} = state, output, _exit_code) do
    if iteration >= max_iterations do
      {:error,
       {:rollback_budget_exhausted,
        %{
          diagnostics: diagnostic_anchors(output),
          plan: state.plan,
          invalid_mutants: Enum.reverse(state.invalid_mutants),
          rollback_iterations: iteration
        }}}
    else
      with {:ok, located} <- locate_output(state.placement_maps, output),
           {:ok, state} <- invalidate_and_render(state, located) do
        compile_and_loop(%{state | iteration: iteration + 1})
      end
    end
  end

  # R5: finite backstop on each rollback-bisection recompile (this loops,
  # recompiling the schema build as it invalidates faulty mutants). `:infinity`
  # would wedge the whole schema phase on a pathological compile.
  @build_timeout_ms 1_200_000

  defp compile_and_loop(state) do
    case Mut.ChildProcess.run("mix", state.compile_args,
           cd: state.work_copy_root,
           env: state.env,
           timeout_ms: @build_timeout_ms
         ) do
      {:exit, exit_code, output} -> loop(state, output, exit_code)
      {:timeout, output} -> {:error, {:compile_timeout, Mut.ChildProcess.output_tail(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp success(state) do
    {:ok,
     %{
       plan: state.plan,
       placement_maps: state.placement_maps,
       invalid_mutants: Enum.reverse(state.invalid_mutants),
       rollback_iterations: state.iteration
     }}
  end

  defp locate_output(placement_maps, output) do
    anchors = diagnostic_anchors(output)
    instrumented_anchors = Enum.filter(anchors, &Map.has_key?(placement_maps, &1.file))

    cond do
      anchors != [] and instrumented_anchors == [] ->
        {:error, {:user_code_compile_failure, hd(anchors)}}

      instrumented_anchors == [] ->
        {:error, {:user_code_compile_failure, :no_diagnostic_anchor}}

      true ->
        locate_anchors(instrumented_anchors, placement_maps)
    end
  end

  defp locate_anchors(anchors, placement_maps) do
    # R10: a compile-time *exception* prints a multi-frame stacktrace
    # (`lib/foo.ex:25: MyMod.caller/1`) whose frames point into instrumented
    # files at lines that carry no mutant entry. Tolerate those un-mappable
    # *frame* anchors instead of aborting the whole schema build. But an
    # un-mappable *primary* diagnostic (an `error:`/`** (…)` header line) is NOT
    # a frame — silently skipping it could mis-invalidate an unrelated mutant
    # that a stray frame happened to map to, so we still abort loudly on it.
    anchors
    |> Enum.reduce_while({:ok, []}, &locate_anchor_step(&1, &2, placement_maps))
    |> case do
      {:ok, []} -> {:error, {:user_code_compile_failure, hd(anchors)}}
      {:ok, located} -> {:ok, Enum.reverse(located)}
      {:error, _reason} = error -> error
    end
  end

  defp locate_anchor_step(anchor, {:ok, located}, placement_maps) do
    case locate_mutants(Map.fetch!(placement_maps, anchor.file), anchor.line) do
      {:ok, mut_ids} -> {:cont, {:ok, [%{anchor: anchor, mut_ids: mut_ids} | located]}}
      :not_found -> skip_frame_or_abort(anchor, located)
    end
  end

  # Tolerate an un-mappable *stacktrace frame* (continue); abort on an
  # un-mappable *primary* diagnostic (it would otherwise mis-invalidate an
  # unrelated mutant that a stray frame mapped to).
  defp skip_frame_or_abort(anchor, located) do
    if stacktrace_frame?(anchor.diagnostic),
      do: {:cont, {:ok, located}},
      else: {:halt, {:error, {:user_code_compile_failure, anchor}}}
  end

  # A trailing stacktrace frame (`[(app vsn) ]lib/foo.ex:NN[:CC]: Mod.fun/arity`)
  # carries no diagnostic keyword and ends in a `: <ref>` suffix; a diagnostic
  # header carries `error:`/`warning:` or an `** (…)` exception tag.
  defp stacktrace_frame?(line) do
    not diagnostic_header?(line) and Regex.match?(~r/\.exs?:\d+(:\d+)?: \S/, line)
  end

  defp diagnostic_header?(line) do
    Regex.match?(~r/(^|\s)(error|warning):/, line) or String.contains?(line, "** (")
  end

  defp invalidate_and_render(state, located) do
    ids_by_file =
      located
      |> Enum.flat_map(fn %{anchor: anchor, mut_ids: ids} ->
        Enum.map(ids, &{&1, anchor.file, anchor.diagnostic})
      end)
      |> Enum.uniq_by(fn {id, _file, _diagnostic} -> id end)
      |> Enum.group_by(&elem(&1, 1))

    {plan, invalidations, invalid_by_file, exhausted_files} =
      apply_invalidations(
        state.plan,
        state.invalid_by_file,
        ids_by_file,
        state.max_invalid_per_file
      )

    affected_files = Map.keys(ids_by_file) |> Enum.concat(exhausted_files) |> Enum.uniq()

    with {:ok, placement_maps} <-
           rerender_files(
             state.work_copy_root,
             plan,
             state.placement_maps,
             state.original_sources,
             affected_files,
             exhausted_files
           ) do
      {:ok,
       %{
         state
         | plan: plan,
           placement_maps: placement_maps,
           invalid_mutants: Enum.reverse(invalidations) ++ state.invalid_mutants,
           invalid_by_file: invalid_by_file
       }}
    end
  end

  defp apply_invalidations(plan, invalid_by_file, ids_by_file, max_invalid_per_file) do
    diagnostics = diagnostics_by_id(ids_by_file)
    initial_ids = Map.keys(diagnostics)
    {plan, invalidations} = move_invalid(plan, initial_ids, diagnostics)

    invalid_by_file =
      Enum.reduce(invalidations, invalid_by_file, fn invalidation, acc ->
        Map.update(
          acc,
          invalidation.file,
          MapSet.new([invalidation.mutant_id]),
          &MapSet.put(&1, invalidation.mutant_id)
        )
      end)

    exhausted_files = exhausted_files(plan, invalid_by_file, ids_by_file, max_invalid_per_file)

    exhausted_ids =
      plan.schema
      |> Enum.filter(&(&1.file in exhausted_files))
      |> Map.new(&{&1.id, "rollback invalidation budget exhausted"})

    {plan, exhausted_invalidations} =
      move_invalid(plan, Map.keys(exhausted_ids), exhausted_ids)

    invalid_by_file =
      Enum.reduce(exhausted_invalidations, invalid_by_file, fn invalidation, acc ->
        Map.update(
          acc,
          invalidation.file,
          MapSet.new([invalidation.mutant_id]),
          &MapSet.put(&1, invalidation.mutant_id)
        )
      end)

    {plan, exhausted_invalidations ++ invalidations, invalid_by_file, exhausted_files}
  end

  defp diagnostics_by_id(ids_by_file) do
    entries = Enum.flat_map(ids_by_file, fn {_file, entries} -> entries end)

    Map.new(entries, fn {id, _file, diagnostic} ->
      {id, diagnostic}
    end)
  end

  defp move_invalid(%Plan{} = plan, ids, diagnostics) do
    id_set = Map.new(ids, &{&1, true})
    {invalid, schema} = Enum.split_with(plan.schema, &Map.has_key?(id_set, &1.id))

    invalid =
      Enum.map(invalid, fn mutant ->
        %{mutant | status: :invalid, compile_error: Map.fetch!(diagnostics, mutant.id)}
      end)

    invalidations =
      Enum.map(invalid, fn mutant ->
        %{
          mutant_id: mutant.id,
          file: mutant.file,
          line: mutant.line,
          diagnostic: mutant.compile_error
        }
      end)

    {%{plan | schema: schema, invalid: plan.invalid ++ invalid}, invalidations}
  end

  defp exhausted_files(plan, invalid_by_file, ids_by_file, max_invalid_per_file) do
    ids_by_file
    |> Map.keys()
    |> Enum.filter(fn file ->
      limit = invalid_limit(max_invalid_per_file, plan, file)
      MapSet.size(Map.get(invalid_by_file, file, MapSet.new())) >= limit
    end)
  end

  defp invalid_limit(nil, plan, file) do
    count = Enum.count(plan.schema ++ plan.invalid, &(&1.file == file))
    max(10, ceil(count * 0.02))
  end

  defp invalid_limit(limit, _plan, _file) when is_integer(limit), do: limit

  defp invalid_limit(fun, plan, file) when is_function(fun, 1) do
    (plan.schema ++ plan.invalid)
    |> Enum.count(&(&1.file == file))
    |> fun.()
  end

  defp rerender_files(
         work_copy_root,
         plan,
         placement_maps,
         original_sources,
         affected_files,
         exhausted_files
       ) do
    Enum.reduce_while(affected_files, {:ok, placement_maps}, fn file, {:ok, maps} ->
      path = Path.join(work_copy_root, file)

      File.write!(path, Map.fetch!(original_sources, file))
      rerender_file(file, path, plan, maps, exhausted_files)
    end)
  end

  defp rerender_file(file, path, plan, maps, exhausted_files) do
    if file in exhausted_files do
      {:cont, {:ok, Map.delete(maps, file)}}
    else
      instrument_file(file, path, plan, maps)
    end
  end

  defp instrument_file(file, path, plan, maps) do
    mutants = Enum.filter(plan.schema, &(&1.file == file))

    case Mut.SchemaPlacer.instrument_file(path, mutants) do
      {:ok, source, placement_map, _refusals} ->
        # During rollback we operate on a subset of mutants that already
        # passed initial schema placement; refusals here would indicate a
        # logic regression. We ignore them rather than crashing the rollback,
        # but the residual mutants stay in `plan.schema` and will be invalid
        # on the next compile pass if they truly cannot be placed.
        File.write!(path, source)
        {:cont, {:ok, Map.put(maps, file, placement_map)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp normalize_file("./" <> file), do: file
  defp normalize_file(file), do: file

  defp initial_invalid_by_file(%Plan{} = plan) do
    Enum.reduce(plan.invalid, %{}, fn mutant, acc ->
      Map.update(acc, mutant.file, MapSet.new([mutant.id]), &MapSet.put(&1, mutant.id))
    end)
  end
end
