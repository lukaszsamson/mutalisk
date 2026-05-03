defmodule Mut.SchemaBuild do
  @moduledoc "Builds schema-instrumented Mix projects."

  alias Mut.Plan

  defmodule Result do
    @moduledoc "Schema build result consumed by sandbox setup."

    defstruct [
      :work_copy_root,
      :build_path,
      :plan,
      :placement_maps,
      :snapshot,
      :rollback_iterations,
      :invalid_mutants
    ]

    @type invalidation :: %{
            mutant_id: non_neg_integer(),
            file: Path.t(),
            line: pos_integer() | nil,
            diagnostic: String.t()
          }

    @type t :: %__MODULE__{
            work_copy_root: Path.t(),
            build_path: Path.t(),
            plan: Plan.t(),
            placement_maps: %{Path.t() => Mut.SchemaPlacer.PlacementMap.t()},
            snapshot: %{Path.t() => String.t()},
            rollback_iterations: non_neg_integer(),
            invalid_mutants: [invalidation]
          }
  end

  @deps_args ["do", "deps.get", "+", "deps.compile", "--include-children", "mutalisk"]
  @compile_args ["compile", "--force"]

  @spec build(Plan.t(), keyword) :: {:ok, Result.t()} | {:error, term}
  def build(%Plan{} = plan, opts) when is_list(opts) do
    with {:ok, user_project_root} <- fetch_user_project_root(opts),
         {:ok, work_copy} <- materialize(user_project_root, opts) do
      result = build_in_work_copy(work_copy, plan, opts)
      maybe_remove_work_copy(work_copy, opts, result)
      result
    end
  end

  @spec snapshot(Path.t()) :: %{Path.t() => String.t()}
  def snapshot(build_path), do: snapshot(build_path, [])

  @spec snapshot(Path.t(), keyword) :: %{Path.t() => String.t()}
  def snapshot(build_path, opts) do
    app = Keyword.get(opts, :app)

    build_path
    |> snapshot_glob(app)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn file ->
      relative = Path.relative_to(file, build_path)
      {relative, sha256(file)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  @spec child_env() :: [{String.t(), String.t()}]
  def child_env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "schema"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())}
    ]
  end

  defp fetch_user_project_root(opts) do
    case Keyword.fetch(opts, :user_project_root) do
      {:ok, root} -> {:ok, Path.expand(root)}
      :error -> {:error, :missing_user_project_root}
    end
  end

  defp materialize(user_project_root, opts) do
    Mut.WorkCopy.materialize(user_project_root, Keyword.get_lazy(opts, :run_id, &run_id/0),
      force: Keyword.get(opts, :force, false)
    )
  end

  defp build_in_work_copy(work_copy, plan, opts) do
    with :ok <- Mut.WorkCopy.install_overlay(work_copy, :schema),
         {:ok, placement_maps, original_sources} <- instrument_files(work_copy, plan),
         :ok <- run_child_mix(work_copy, @deps_args),
         {:compile, output, exit_code} <- compile(work_copy),
         {:ok, final} <-
           handle_compile(
             work_copy,
             plan,
             placement_maps,
             original_sources,
             output,
             exit_code,
             opts
           ),
         :ok <- restore_original_sources(work_copy, original_sources) do
      {:ok, result(work_copy, final)}
    else
      {:compile, output, exit_code} -> {:error, {:compile_failed, exit_code, output_tail(output)}}
      {:error, _reason} = error -> error
    end
  end

  defp instrument_files(work_copy, %Plan{} = plan) do
    plan.schema
    |> Enum.group_by(& &1.file)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {file, mutants}, {:ok, maps, originals} ->
      work_file = Path.join(work_copy, file)
      original_source = File.read!(work_file)

      case Mut.SchemaPlacer.instrument_file(work_file, mutants) do
        {:ok, source, placement_map} ->
          File.write!(work_file, source)

          {:cont,
           {:ok, Map.put(maps, file, placement_map), Map.put(originals, file, original_source)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_original_sources(work_copy, original_sources) do
    Enum.each(original_sources, fn {file, source} ->
      File.write!(Path.join(work_copy, file), source)
    end)

    :ok
  end

  defp handle_compile(_work_copy, plan, placement_maps, _original_sources, _output, 0, _opts) do
    {:ok,
     %{
       plan: plan,
       placement_maps: placement_maps,
       invalid_mutants: [],
       rollback_iterations: 0
     }}
  end

  defp handle_compile(work_copy, plan, placement_maps, original_sources, output, _exit_code, opts) do
    rollback_opts =
      opts
      |> Keyword.get(:rollback, [])
      |> Keyword.put_new(:env, child_env())
      |> Keyword.put_new(:compile_args, @compile_args)
      |> Keyword.put(:original_sources, original_sources)
      |> Keyword.put(:initial_output, output)

    case Mut.CompileRollback.run(work_copy, plan, placement_maps, rollback_opts) do
      {:ok, final} -> {:ok, final}
      {:error, reason} -> {:error, {:schema_build_failed, reason}}
    end
  end

  defp result(work_copy, final) do
    build_path = Path.join(work_copy, "_build/mut_schema")
    app = target_app(work_copy)

    %Result{
      work_copy_root: work_copy,
      build_path: build_path,
      plan: final.plan,
      placement_maps: final.placement_maps,
      snapshot: snapshot(build_path, app: app),
      rollback_iterations: final.rollback_iterations,
      invalid_mutants: final.invalid_mutants
    }
  end

  defp run_child_mix(work_copy, args) do
    case System.cmd("mix", args, cd: work_copy, env: child_env(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:compile_failed, exit_code, output_tail(output)}}
    end
  end

  defp compile(work_copy) do
    {output, exit_code} =
      System.cmd("mix", @compile_args, cd: work_copy, env: child_env(), stderr_to_stdout: true)

    {:compile, output, exit_code}
  end

  defp maybe_remove_work_copy(work_copy, opts, result) do
    keep? = Keyword.get(opts, :keep, false)
    keep_failed? = Keyword.get(opts, :keep_failed, false)

    if keep? or (keep_failed? and match?({:error, _reason}, result)) do
      :ok
    else
      File.rm_rf!(work_copy)
      :ok
    end
  end

  defp snapshot_glob(build_path, nil), do: Path.join(build_path, "**/*")
  defp snapshot_glob(build_path, app), do: Path.join([build_path, "lib", app, "**/*"])

  defp target_app(work_copy) do
    work_copy
    |> Path.join("mix_user.exs")
    |> File.read!()
    |> Code.string_to_quoted!()
    |> app_from_ast()
  end

  defp app_from_ast(ast) do
    {_ast, app} =
      Macro.prewalk(ast, nil, fn
        {:app, _meta, value}, nil when is_atom(value) ->
          {{:app, [], value}, Atom.to_string(value)}

        {:app, value}, nil when is_atom(value) ->
          {{:app, value}, Atom.to_string(value)}

        node, app ->
          {node, app}
      end)

    app
  end

  defp sha256(file) do
    :sha256
    |> :crypto.hash(File.read!(file))
    |> Base.encode16(case: :lower)
  end

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "schema-#{System.os_time(:second)}-#{random}"
  end
end
