defmodule Mut.WorkCopy do
  @moduledoc "Creates isolated working copies for target projects."

  require Logger

  alias Mut.Bootstrap.Overlay

  @symlink_entries ["deps", "config", "priv"]
  @transient_entries ["_build", "tmp"]

  @spec materialize(Path.t(), String.t(), keyword) :: {:ok, Path.t()} | {:error, term}
  def materialize(user_project_root, run_id, opts \\ [])
      when is_binary(run_id) and is_list(opts) do
    user_project_root = Path.expand(user_project_root)
    work_copy = Path.expand(Path.join([File.cwd!(), "tmp", "mut_work", run_id]))

    with :ok <- assert_mix_project(user_project_root),
         :ok <- prepare_destination(work_copy, Keyword.get(opts, :force, false)),
         :ok <- copy_project(user_project_root, work_copy),
         :ok <- remove_transient_entries(work_copy),
         :ok <- symlink_project_entries(user_project_root, work_copy) do
      {:ok, work_copy}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @spec install_overlay(Path.t(), Overlay.role()) :: :ok | {:error, term}
  def install_overlay(work_copy, role) when role in [:oracle, :schema] do
    case Overlay.materialize(work_copy, role) do
      {:error, {:already_installed, _path}} ->
        raise RuntimeError, "overlay already installed: #{work_copy}"

      {:error, {:not_a_mix_project, _path}} ->
        raise RuntimeError, "not a mix project: #{work_copy}"

      other ->
        other
    end
  end

  defp assert_mix_project(root) do
    if File.exists?(Path.join(root, "mix.exs")) do
      :ok
    else
      {:error, {:not_a_mix_project, root}}
    end
  end

  defp prepare_destination(work_copy, force?) do
    cond do
      File.exists?(work_copy) and force? ->
        File.rm_rf!(work_copy)
        File.mkdir_p!(Path.dirname(work_copy))
        :ok

      File.exists?(work_copy) ->
        {:error, {:already_exists, work_copy}}

      true ->
        File.mkdir_p!(Path.dirname(work_copy))
        :ok
    end
  end

  defp copy_project(source, destination) do
    case cow_copy(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("COW copy failed; falling back to plain copy: #{inspect(reason)}")
        File.cp_r!(source, destination)
        :ok
    end
  end

  defp cow_copy(source, destination) do
    case :os.type() do
      {:unix, :darwin} -> run_cp(["-Rc", source, destination])
      {:unix, :linux} -> run_cp(["-R", "--reflink=auto", source, destination])
      _other -> {:error, :unsupported_platform}
    end
  end

  defp run_cp(args) do
    case System.cmd("cp", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:cp_failed, exit_code, output}}
    end
  end

  defp symlink_project_entries(user_project_root, work_copy) do
    Enum.each(@symlink_entries, fn entry ->
      source = Path.join(user_project_root, entry)
      target = Path.join(work_copy, entry)

      if File.exists?(source) or match?({:ok, _stat}, File.lstat(source)) do
        File.rm_rf!(target)
        :ok = File.ln_s(source, target)
      end
    end)

    :ok
  end

  defp remove_transient_entries(work_copy) do
    Enum.each(@transient_entries, fn entry ->
      File.rm_rf!(Path.join(work_copy, entry))
    end)

    :ok
  end
end
