defmodule Mut.WorkCopy do
  @moduledoc "Creates isolated working copies for target projects."

  require Logger

  alias Mut.Bootstrap.Overlay

  # R15: `priv` is COPIED, not symlinked. A symlink pointed every sandbox's
  # `priv` at the user's REAL project dir, so tests writing under `priv` (SQLite
  # DBs, generated assets, Mnesia) mutated the user's project and contended
  # across concurrent sandboxes. `copy_project/2` already copies `priv` (cheaply,
  # copy-on-write where supported); dropping it from the symlink set leaves that
  # isolated copy in place. `deps`/`config` are read-only at test time and stay
  # symlinked to avoid duplicating large dependency trees.
  @symlink_entries ["deps", "config"]
  @transient_entries ["_build", "tmp"]

  @doc """
  Materializes an isolated work copy of `user_project_root`.

  ## Options

    * `:root` - base directory for the copy.
    * `:force` - overwrite an existing copy at the target path.
    * `:keep_failed` - keep a partially built copy for debugging when a
      post-copy step fails (default `false`).

  T29: a failure AFTER the project has been copied (overlay/symlink/transient
  cleanup, or an exception in any of them) used to return `{:error, reason}`
  while leaving a full project copy behind that nothing ever removes — the
  caller has no path to clean up. The copy is deleted before the error is
  returned unless `:keep_failed` asks for it. Failures BEFORE the copy
  (`:not_a_mix_project`, `:already_exists`) never delete anything: the path
  either does not exist or belongs to someone else.
  """
  @spec materialize(Path.t(), String.t(), keyword) :: {:ok, Path.t()} | {:error, term}
  def materialize(user_project_root, run_id, opts \\ [])
      when is_binary(run_id) and is_list(opts) do
    user_project_root = Path.expand(user_project_root)
    # #40/#49: the artifact base is supplied explicitly by the caller so work
    # copies never depend on the process cwd. The default (`<cwd>/tmp`) preserves
    # the historic layout used by mutalisk's own test suite; `mix mut` passes a
    # target-scoped OS-temp root so nothing lands under the dependency checkout.
    root = Keyword.get(opts, :root) || Path.join(File.cwd!(), "tmp")
    work_copy = Path.expand(Path.join([root, "mut_work", run_id]))

    with :ok <- assert_mix_project(user_project_root),
         :ok <- prepare_destination(work_copy, Keyword.get(opts, :force, false)),
         :ok <- copy_project(user_project_root, work_copy) do
      finish_materialize(user_project_root, work_copy, opts)
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp finish_materialize(user_project_root, work_copy, opts) do
    with :ok <- remove_transient_entries(work_copy),
         :ok <- symlink_project_entries(user_project_root, work_copy),
         :ok <- post_copy_hook(opts).(work_copy) do
      {:ok, work_copy}
    else
      {:error, reason} -> discard_work_copy(work_copy, opts, reason)
    end
  rescue
    exception ->
      discard_work_copy(
        work_copy,
        opts,
        {exception.__struct__, Exception.message(exception)}
      )
  end

  # Test seam: injects an extra post-copy step so the cleanup-on-failure path
  # can be exercised. (Provoking a real link failure needs permission tricks
  # that would defeat the cleanup itself, hiding the very thing under test.)
  defp post_copy_hook(opts) do
    case Keyword.get(opts, :post_copy) do
      fun when is_function(fun, 1) -> fun
      nil -> fn _work_copy -> :ok end
    end
  end

  defp discard_work_copy(work_copy, opts, reason) do
    unless Keyword.get(opts, :keep_failed, false) do
      File.rm_rf(work_copy)
    end

    {:error, reason}
  end

  @spec install_overlay(Path.t(), Overlay.role()) :: :ok | {:error, term}
  def install_overlay(work_copy, role) when role in [:oracle, :schema, :coverage] do
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
    case Mut.FileCopy.cow_copy(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("COW copy failed; falling back to plain copy: #{inspect(reason)}")
        File.cp_r!(source, destination)
        :ok
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
