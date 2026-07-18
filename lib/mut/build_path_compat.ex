defmodule Mut.BuildPathCompat do
  @moduledoc """
  Compatibility helpers for projects that reference Mix's conventional test build path.

  Mutalisk runs target projects under isolated build paths such as
  `_build/mut_oracle` and `_build/mut_schema`. Some real projects still create
  test fixtures under `_build/test/lib/<app>` while reading them back through
  `Application.app_dir/2`, which resolves against the active `MIX_BUILD_PATH`.
  In disposable work copies, alias `_build/test` to the active build path so
  those two public Mix conventions continue to agree.
  """

  @spec alias_test_build_path(Path.t(), Path.t()) :: :ok | {:error, term()}
  def alias_test_build_path(root, build_path)
      when is_binary(root) and is_binary(build_path) do
    root = Path.expand(root)
    build_path = Path.expand(build_path, root)
    test_path = Path.join([root, "_build", "test"])
    link_target = Path.relative_to(build_path, Path.dirname(test_path))

    File.mkdir_p!(build_path)
    File.mkdir_p!(Path.dirname(test_path))

    case File.lstat(test_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        relink(test_path, link_target)

      {:ok, _stat} ->
        File.rm_rf!(test_path)
        File.ln_s!(link_target, test_path)
        :ok

      {:error, :enoent} ->
        File.ln_s!(link_target, test_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp relink(test_path, link_target) do
    case File.read_link(test_path) do
      {:ok, ^link_target} ->
        :ok

      _other ->
        File.rm!(test_path)
        File.ln_s!(link_target, test_path)
        :ok
    end
  end
end
