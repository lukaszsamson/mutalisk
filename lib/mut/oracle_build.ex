defmodule Mut.OracleBuild do
  @moduledoc "Builds the dispatch oracle in an isolated working copy."

  @spec run(Path.t(), keyword) :: {:ok, Mut.Oracle.t()} | {:error, term}
  def run(user_project_root, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)
    keep? = Keyword.get(opts, :keep, false)

    case Mut.WorkCopy.materialize(user_project_root, run_id,
           force: Keyword.get(opts, :force, false)
         ) do
      {:ok, work_copy} ->
        result = build_oracle(work_copy)
        maybe_remove_work_copy(work_copy, keep?)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp build_oracle(work_copy) do
    with :ok <- Mut.WorkCopy.install_overlay(work_copy, :oracle),
         :ok <-
           run_child_mix(work_copy, [
             "do",
             "deps.get",
             "+",
             "deps.compile",
             "--include-children",
             "mutalisk"
           ]),
         :ok <- run_child_mix(work_copy, ["compile", "--force"]),
         {:ok, _count} <-
           Mut.Oracle.load_jsonl(
             Path.join([work_copy, "_build", "mut_oracle", ".mut_oracle.jsonl"])
           ) do
      {:ok, Mut.Oracle.snapshot()}
    end
  end

  defp run_child_mix(work_copy, args) do
    case System.cmd("mix", args, cd: work_copy, env: child_env(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:compile_failed, exit_code, output_tail(output)}}
    end
  end

  defp child_env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_oracle"},
      {"MIX_DEPS_PATH", "_build/mut_oracle/deps"},
      {"MUTALISK_ROLE", "oracle"},
      {"MUTALISK_PATH", File.cwd!()}
    ]
  end

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp maybe_remove_work_copy(_work_copy, true), do: :ok

  defp maybe_remove_work_copy(work_copy, false) do
    File.rm_rf!(work_copy)
    :ok
  end

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "oracle-#{System.os_time(:second)}-#{random}"
  end
end
