defmodule Mut.Sandbox do
  @moduledoc "Manages isolated worker sandboxes."

  alias Mut.SchemaBuild

  defstruct [
    :id,
    :path,
    :baseline_snapshot,
    :baseline_source
  ]

  @type t :: %__MODULE__{
          id: pos_integer,
          path: Path.t(),
          baseline_snapshot: %{Path.t() => String.t()},
          baseline_source: Path.t()
        }

  defmodule Pool do
    @moduledoc "Sandbox pool state."

    defstruct [
      :run_id,
      :sandboxes,
      :checked_out,
      :schema_result
    ]

    @type t :: %__MODULE__{
            run_id: String.t(),
            sandboxes: MapSet.t(Mut.Sandbox.t()),
            checked_out: MapSet.t(Mut.Sandbox.t()),
            schema_result: Mut.SchemaBuild.Result.t()
          }
  end

  @sandbox_root Path.join(["tmp", "mut_sandboxes"])

  @spec create_pool(SchemaBuild.Result.t(), pos_integer, keyword) ::
          {:ok, Pool.t()} | {:error, term}
  def create_pool(%SchemaBuild.Result{} = schema_result, concurrency, opts \\ [])
      when is_integer(concurrency) and concurrency > 0 and is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)
    parent = pool_path(run_id)

    with :ok <- prepare_parent(parent, Keyword.get(opts, :force, false)),
         {:ok, sandboxes} <- create_sandboxes(schema_result, concurrency, parent) do
      {:ok,
       %Pool{
         run_id: run_id,
         sandboxes: MapSet.new(sandboxes),
         checked_out: MapSet.new(),
         schema_result: schema_result
       }}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @spec checkout(Pool.t()) :: {:ok, t, Pool.t()} | {:error, :pool_empty}
  def checkout(%Pool{sandboxes: sandboxes} = pool) do
    case Enum.min_by(sandboxes, & &1.id, fn -> nil end) do
      nil ->
        {:error, :pool_empty}

      %__MODULE__{} = sandbox ->
        {:ok, sandbox,
         %{
           pool
           | sandboxes: MapSet.delete(pool.sandboxes, sandbox),
             checked_out: MapSet.put(pool.checked_out, sandbox)
         }}
    end
  end

  @spec checkin(t, Pool.t()) :: Pool.t()
  def checkin(%__MODULE__{} = sandbox, %Pool{} = pool) do
    if MapSet.member?(pool.checked_out, sandbox) do
      %{
        pool
        | sandboxes: MapSet.put(pool.sandboxes, sandbox),
          checked_out: MapSet.delete(pool.checked_out, sandbox)
      }
    else
      pool
    end
  end

  @spec reset(t) :: :ok | {:error, term}
  def reset(%__MODULE__{} = sandbox) do
    with :ok <- restore_baseline_files(sandbox),
         :ok <- remove_stray_files(sandbox),
         :ok <- verify_baseline(sandbox) do
      :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @spec destroy_pool(Pool.t()) :: :ok
  def destroy_pool(%Pool{} = pool) do
    pool.sandboxes
    |> MapSet.union(pool.checked_out)
    |> Enum.each(&File.rm_rf!(&1.path))

    File.rm_rf!(pool_path(pool.run_id))
    :ok
  end

  defp prepare_parent(parent, force?) do
    cond do
      File.exists?(parent) and force? ->
        File.rm_rf!(parent)
        File.mkdir_p!(parent)
        :ok

      File.exists?(parent) ->
        {:error, {:already_exists, parent}}

      true ->
        File.mkdir_p!(parent)
        :ok
    end
  end

  defp create_sandboxes(schema_result, concurrency, parent) do
    sandboxes =
      Enum.map(1..concurrency, fn id ->
        path = Path.join(parent, Integer.to_string(id))
        :ok = Mut.FileCopy.copy_tree(schema_result.work_copy_root, path)

        %__MODULE__{
          id: id,
          path: path,
          baseline_snapshot: schema_result.snapshot,
          baseline_source: schema_result.work_copy_root
        }
      end)

    {:ok, sandboxes}
  end

  defp restore_baseline_files(sandbox) do
    Enum.each(sandbox.baseline_snapshot, fn {relative, expected_hash} ->
      target = sandbox_file(sandbox, relative)

      if sha256(target) != expected_hash do
        source = baseline_file(sandbox, relative)
        File.mkdir_p!(Path.dirname(target))
        File.rm_rf!(target)
        :ok = Mut.FileCopy.copy_tree(source, target)
      end
    end)

    :ok
  end

  defp remove_stray_files(sandbox) do
    baseline_paths = MapSet.new(Map.keys(sandbox.baseline_snapshot))
    baseline_roots = baseline_roots(baseline_paths)

    snapshot_root(sandbox.path)
    |> all_files()
    |> Enum.each(fn file ->
      relative = Path.relative_to(file, snapshot_root(sandbox.path))

      if tracked_root?(relative, baseline_roots) and not MapSet.member?(baseline_paths, relative) do
        File.rm!(file)
      end
    end)

    :ok
  end

  defp verify_baseline(sandbox) do
    mismatches =
      Enum.reject(sandbox.baseline_snapshot, fn {relative, expected_hash} ->
        sandbox
        |> sandbox_file(relative)
        |> sha256() == expected_hash
      end)

    if mismatches == [],
      do: :ok,
      else: {:error, {:reset_mismatch, Enum.map(mismatches, &elem(&1, 0))}}
  end

  defp all_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp baseline_roots(paths) do
    paths
    |> Enum.map(fn path -> path |> Path.split() |> List.first() end)
    |> MapSet.new()
  end

  defp tracked_root?(relative, roots) do
    relative
    |> Path.split()
    |> List.first()
    |> then(&MapSet.member?(roots, &1))
  end

  defp sha256(path) do
    if File.regular?(path) do
      :sha256
      |> :crypto.hash(File.read!(path))
      |> Base.encode16(case: :lower)
    end
  end

  defp sandbox_file(sandbox, relative), do: Path.join(snapshot_root(sandbox.path), relative)

  defp baseline_file(sandbox, relative),
    do: Path.join(snapshot_root(sandbox.baseline_source), relative)

  defp snapshot_root(root), do: Path.join(root, "_build/mut_schema")

  defp pool_path(run_id), do: Path.expand(Path.join(@sandbox_root, run_id))

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "schema-#{System.os_time(:second)}-#{random}"
  end
end
