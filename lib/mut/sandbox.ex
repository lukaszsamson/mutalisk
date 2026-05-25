defmodule Mut.Sandbox do
  @moduledoc "Manages isolated worker sandboxes."

  @dialyzer {:no_opaque, checkin: 2, destroy_pool: 1}

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
            sandboxes: term,
            checked_out: term,
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
    baseline = baseline(sandbox)
    :ok = restore_baseline_files(sandbox, baseline)
    :ok = remove_stray_files(sandbox)
    verify_baseline(sandbox, baseline)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @spec destroy_pool(Pool.t()) :: :ok
  def destroy_pool(%Pool{} = pool) do
    pool.sandboxes
    |> MapSet.union(pool.checked_out)
    |> Enum.uniq_by(& &1.path)
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
    Enum.reduce_while(1..concurrency, {:ok, []}, fn id, {:ok, sandboxes} ->
      path = Path.join(parent, Integer.to_string(id))

      with :ok <- Mut.FileCopy.copy_tree(schema_result.work_copy_root, path),
           :ok <- assert_materialized(path) do
        sandbox = %__MODULE__{
          id: id,
          path: path,
          baseline_snapshot: schema_result.snapshot,
          baseline_source: schema_result.work_copy_root
        }

        {:cont, {:ok, [sandbox | sandboxes]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sandboxes} -> {:ok, Enum.reverse(sandboxes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assert_materialized(path) do
    cond do
      not File.exists?(Path.join(path, "mix.exs")) ->
        {:error, {:missing_mix_exs, path}}

      match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(path, "_build/mut_schema"))) ->
        {:error, {:schema_build_is_symlink, Path.join(path, "_build/mut_schema")}}

      not File.dir?(Path.join(path, "_build/mut_schema")) ->
        {:error, {:missing_schema_build, Path.join(path, "_build/mut_schema")}}

      true ->
        :ok
    end
  end

  defp restore_baseline_files(sandbox, baseline) do
    Enum.each(baseline, fn {relative, expected_hash} ->
      target = Path.join(sandbox.path, relative)

      if sha256(target) != expected_hash do
        source = Path.join(sandbox.baseline_source, relative)
        File.mkdir_p!(Path.dirname(target))
        File.rm_rf!(target)
        :ok = Mut.FileCopy.copy_tree(source, target)
      end
    end)

    :ok
  end

  defp remove_stray_files(sandbox) do
    baseline_paths = baseline(sandbox)
    baseline_roots = baseline_roots(baseline_paths)

    sandbox.path
    |> all_files()
    |> Enum.each(fn file ->
      relative = Path.relative_to(file, sandbox.path)

      if tracked_root?(relative, baseline_roots) and not Map.has_key?(baseline_paths, relative) do
        File.rm!(file)
      end
    end)

    :ok
  end

  defp verify_baseline(sandbox, baseline) do
    mismatches =
      Enum.reject(baseline, fn {relative, expected_hash} ->
        sandbox.path
        |> Path.join(relative)
        |> sha256() == expected_hash
      end)

    if mismatches == [],
      do: :ok,
      else: {:error, {:reset_mismatch, Enum.map(mismatches, &elem(&1, 0))}}
  end

  defp all_files(root) do
    root
    |> do_all_files()
    |> Enum.filter(&File.regular?/1)
  end

  defp do_all_files(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(root, entry)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> do_all_files(path)
        {:ok, %File.Stat{type: :symlink}} -> []
        {:ok, _stat} -> [path]
        {:error, _reason} -> []
      end
    end)
  end

  # Tracked roots are the prefixes of baseline files that bound stray-file
  # removal. We use the first segment for source paths (so all of `lib/`
  # is tracked) but the first FOUR segments for `_build/` paths (so we
  # only sweep within `_build/<build>/lib/<user_app>/`, leaving sibling
  # apps like mutalisk and deps' ebins untouched). Without this, reset
  # would delete `_build/mut_schema/lib/mutalisk/ebin/mutalisk.app`,
  # breaking subsequent `mix test` runs in the sandbox.
  defp baseline_roots(paths) do
    paths
    |> Map.keys()
    |> Enum.map(&path_root/1)
    |> Map.new(&{&1, true})
  end

  defp tracked_root?(relative, roots), do: Map.has_key?(roots, path_root(relative))

  defp path_root(relative) do
    case Path.split(relative) do
      ["_build" | _] = parts -> parts |> Enum.take(4) |> Path.join()
      # Umbrella source: confine stray-sweeping to apps/<app>/lib (not all of
      # apps/, which holds each app's mix.exs/test/priv that aren't tracked).
      ["apps", _app, "lib" | _] = parts -> parts |> Enum.take(3) |> Path.join()
      [first | _] -> first
    end
  end

  defp baseline(sandbox) do
    sandbox.baseline_snapshot
    |> Enum.into(%{}, fn {relative, hash} -> {Path.join("_build/mut_schema", relative), hash} end)
    |> Map.merge(source_baseline(sandbox.baseline_source))
  end

  defp source_baseline(baseline_source) do
    baseline_source
    |> source_globs()
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn file ->
      relative = Path.relative_to(file, baseline_source)
      {relative, sha256(file)}
    end)
  end

  # Single-app: the project's own lib/. Umbrella: every child app's lib/, so a
  # fallback-patched source file under apps/<app>/lib resets between mutants
  # (the umbrella root has no lib/ of its own). M68.
  defp source_globs(baseline_source) do
    if Mut.Umbrella.umbrella?(baseline_source) do
      baseline_source
      |> Mut.Umbrella.app_dirs()
      |> Enum.map(&Path.join(&1, "lib/**/*"))
    else
      [Path.join(baseline_source, "lib/**/*")]
    end
  end

  defp sha256(path) do
    if File.regular?(path) do
      :sha256
      |> :crypto.hash(File.read!(path))
      |> Base.encode16(case: :lower)
    end
  end

  defp pool_path(run_id), do: Path.expand(Path.join(@sandbox_root, run_id))

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "schema-#{System.os_time(:second)}-#{random}"
  end
end
