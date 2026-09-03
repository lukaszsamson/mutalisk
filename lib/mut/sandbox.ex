defmodule Mut.Sandbox do
  @moduledoc "Manages isolated worker sandboxes."

  @dialyzer {:no_opaque, checkin: 2, destroy_pool: 1}

  alias Mut.SchemaBuild

  defstruct [
    :id,
    :path,
    :baseline_snapshot,
    :baseline_source,
    :priv_baseline
  ]

  @typedoc """
  A baseline entry is either a content hash (hex sha256) or a stat
  fingerprint `{:stat, size, mtime_posix}`. The stored value decides which
  fingerprint is recomputed for the comparison, so both kinds coexist in one
  baseline map (see `:priv_fingerprint`).
  """
  @type fingerprint :: String.t() | {:stat, non_neg_integer, integer}

  @type t :: %__MODULE__{
          id: pos_integer,
          path: Path.t(),
          baseline_snapshot: %{Path.t() => String.t()},
          baseline_source: Path.t(),
          priv_baseline: %{Path.t() => fingerprint} | nil
        }

  defmodule Pool do
    @moduledoc "Sandbox pool state."

    defstruct [
      :run_id,
      :sandboxes,
      :checked_out,
      :schema_result,
      :parent
    ]

    @type t :: %__MODULE__{
            run_id: String.t(),
            sandboxes: term,
            checked_out: term,
            schema_result: Mut.SchemaBuild.Result.t(),
            parent: Path.t()
          }
  end

  # #40/#49: the sandbox base defaults to a cwd-relative `tmp/mut_sandboxes`
  # (used by mutalisk's own test suite), but `mix mut` passes an explicit
  # target-scoped OS-temp root via the `:root` option so no sandbox is ever
  # created under the dependency checkout.
  @sandbox_dir "mut_sandboxes"
  @default_sandbox_root "tmp"

  @doc """
  Creates a sandbox pool from a schema build result.

  ## Options

    * `:run_id`, `:root`, `:force` - pool location/overwrite control.
    * `:priv_fingerprint` - `:stat` (default) or `:hash`; how the copied
      `priv/` baseline is fingerprinted. See the `priv/` note on `reset/1`.

  A partially created pool is never leaked: if sandbox N fails to
  materialize, sandboxes 1..N-1 and the pool parent are removed before the
  error is returned (T28).
  """
  @spec create_pool(SchemaBuild.Result.t(), pos_integer, keyword) ::
          {:ok, Pool.t()} | {:error, term}
  def create_pool(%SchemaBuild.Result{} = schema_result, concurrency, opts \\ [])
      when is_integer(concurrency) and concurrency > 0 and is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)
    root = Keyword.get(opts, :root) || @default_sandbox_root
    parent = pool_path(run_id, root)
    config = {copy_fun(opts), priv_fingerprint_mode(opts)}

    with :ok <- prepare_parent(parent, Keyword.get(opts, :force, false)),
         {:ok, sandboxes} <-
           create_sandboxes_or_clean(schema_result, concurrency, parent, config) do
      {:ok,
       %Pool{
         run_id: run_id,
         sandboxes: MapSet.new(sandboxes),
         checked_out: MapSet.new(),
         schema_result: schema_result,
         parent: parent
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

  @doc """
  Restores a sandbox to its baseline: the schema build, the project sources
  and the copied `priv/` trees.

  `priv/` is COPIED into every work copy (see `Mut.WorkCopy`) precisely so
  tests may write SQLite/Mnesia databases and generated assets there. Those
  writes survive a mutant run, so without restoring them mutant A's leftovers
  reach mutant B (false kills/survivors, order dependence) — T26.

  `priv/` entries are fingerprinted by `size + mtime` (`:stat`) rather than
  content, because `priv/` routinely holds large binary assets and hashing
  them on every reset (twice — source and sandbox) costs real wall-clock per
  mutant. Trade-off: a rewrite that keeps the byte size AND lands in the same
  mtime second (the resolution `:file.read_file_info/2` exposes) is not
  detected. Pass `priv_fingerprint: :hash` to `create_pool/3` for
  content-exact detection at full hashing cost. Restored `priv` files have
  their mtime reset to the recorded baseline value so the fingerprint is
  stable across resets.
  """
  @spec reset(t) :: :ok | {:error, term}
  def reset(%__MODULE__{} = sandbox) do
    baseline = baseline(sandbox)
    :ok = restore_baseline_files(sandbox, baseline)
    :ok = remove_stray_files(sandbox)
    verify_baseline(sandbox, baseline)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc """
  Restores only the copied `priv/` trees.

  Schema-engine runs never patch sources and never recompile into the
  sandbox (the mutant is selected at runtime via `MUT_ACTIVE`), so the
  build/source baseline cannot drift and the expensive part of `reset/1`
  (hashing every beam) is pure overhead for them. Their tests DO write under
  `priv/`, though, so schema workers reset that much between mutants — a
  stat-only walk of `priv/`, cheap enough to run per mutant (T26).
  """
  @spec reset_priv(t) :: :ok | {:error, term}
  def reset_priv(%__MODULE__{priv_baseline: nil}), do: :ok

  def reset_priv(%__MODULE__{priv_baseline: baseline} = sandbox) do
    :ok = restore_baseline_files(sandbox, baseline)
    :ok = remove_stray_priv_files(sandbox, baseline)
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

    File.rm_rf!(pool.parent)
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

  # T28: a failure part-way through pool creation used to leave sandboxes
  # 1..N-1 (each a full project copy) and the pool parent on disk forever —
  # `destroy_pool/1` never runs because no pool is returned. Everything this
  # call created is removed before the error propagates.
  defp create_sandboxes_or_clean(schema_result, concurrency, parent, config) do
    case create_sandboxes(schema_result, concurrency, parent, config) do
      {:ok, sandboxes} ->
        {:ok, sandboxes}

      {:error, reason, created} ->
        Enum.each(created, &File.rm_rf(&1.path))
        File.rm_rf(parent)
        {:error, reason}
    end
  end

  defp create_sandboxes(schema_result, concurrency, parent, {copy_fun, priv_mode}) do
    Enum.reduce_while(1..concurrency, {:ok, []}, fn id, {:ok, sandboxes} ->
      path = Path.join(parent, Integer.to_string(id))

      with :ok <- copy_fun.(schema_result.work_copy_root, path),
           :ok <- assert_materialized(path) do
        sandbox = %__MODULE__{
          id: id,
          path: path,
          baseline_snapshot: schema_result.snapshot,
          baseline_source: schema_result.work_copy_root,
          priv_baseline: capture_priv_baseline(path, priv_mode)
        }

        {:cont, {:ok, [sandbox | sandboxes]}}
      else
        # The failing sandbox's own partial copy is cleaned up too: `path` is
        # not in `sandboxes` yet, so it is added to the removal list here.
        {:error, reason} ->
          {:halt, {:error, reason, [%{path: path} | sandboxes]}}
      end
    end)
    |> case do
      {:ok, sandboxes} -> {:ok, Enum.reverse(sandboxes)}
      {:error, reason, created} -> {:error, reason, created}
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
    Enum.each(baseline, fn {relative, expected} ->
      target = Path.join(sandbox.path, relative)

      if fingerprint(target, expected) != expected do
        source = Path.join(sandbox.baseline_source, relative)
        File.mkdir_p!(Path.dirname(target))
        File.rm_rf!(target)
        :ok = Mut.FileCopy.copy_tree(source, target)
        restore_mtime(target, expected)
      end
    end)

    :ok
  end

  # A fresh copy carries the copy's mtime, not the baseline's, so a stat
  # fingerprint would never converge. Stamp the recorded mtime back on.
  defp restore_mtime(target, {:stat, _size, mtime}), do: File.touch!(target, mtime)
  defp restore_mtime(_target, _expected), do: :ok

  defp remove_stray_files(sandbox) do
    baseline_paths = baseline(sandbox)
    apps_dir = Mut.Umbrella.apps_path_name(sandbox.path)
    baseline_roots = baseline_roots(sandbox, baseline_paths, apps_dir)

    sandbox.path
    |> all_files()
    |> Enum.each(fn file ->
      relative = Path.relative_to(file, sandbox.path)

      if tracked_root?(relative, baseline_roots, apps_dir) and
           not Map.has_key?(baseline_paths, relative) do
        File.rm!(file)
      end
    end)

    :ok
  end

  # The cheap counterpart of `remove_stray_files/1`: walks only the `priv`
  # trees instead of the whole sandbox.
  defp remove_stray_priv_files(sandbox, baseline) do
    sandbox.path
    |> priv_dirs()
    |> Enum.flat_map(&all_files/1)
    |> Enum.each(fn file ->
      relative = Path.relative_to(file, sandbox.path)

      unless Map.has_key?(baseline, relative) do
        File.rm!(file)
      end
    end)

    :ok
  end

  defp verify_baseline(sandbox, baseline) do
    mismatches =
      Enum.reject(baseline, fn {relative, expected} ->
        sandbox.path
        |> Path.join(relative)
        |> fingerprint(expected) == expected
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
  #
  # `priv/` roots are added unconditionally (not merely derived from baseline
  # entries) so a project whose `priv/` starts out empty — or absent from the
  # baseline — still has test-written files swept (T26).
  defp baseline_roots(sandbox, paths, apps_dir) do
    paths
    |> Map.keys()
    |> Enum.map(&path_root(&1, apps_dir))
    |> Map.new(&{&1, true})
    |> Map.merge(priv_roots(sandbox))
  end

  defp priv_roots(sandbox) do
    sandbox.path
    |> priv_dirs()
    |> Map.new(&{Path.relative_to(&1, sandbox.path), true})
  end

  defp tracked_root?(relative, roots, apps_dir),
    do: Map.has_key?(roots, path_root(relative, apps_dir))

  defp path_root(relative, apps_dir) do
    case Path.split(relative) do
      ["_build" | _] = parts ->
        parts |> Enum.take(4) |> Path.join()

      # Umbrella source: confine stray-sweeping to <apps_path>/<app>/lib and
      # <apps_path>/<app>/priv (not all of <apps_path>/, which holds each app's
      # mix.exs/test that aren't tracked). `apps_dir` honors a custom
      # `:apps_path` (default "apps").
      [^apps_dir, _app, sub | _] = parts when sub in ["lib", "priv"] ->
        parts |> Enum.take(3) |> Path.join()

      [first | _] ->
        first
    end
  end

  defp baseline(sandbox) do
    sandbox.baseline_snapshot
    |> Enum.into(%{}, fn {relative, hash} -> {Path.join("_build/mut_schema", relative), hash} end)
    |> Map.merge(source_baseline(sandbox.baseline_source))
    |> Map.merge(sandbox.priv_baseline || %{})
  end

  # The `priv` baseline is captured from the sandbox itself at creation (the
  # copy is byte-identical to `baseline_source`, which is where restores come
  # from) because a stat fingerprint is only meaningful against the mtimes the
  # copy actually produced — `cp`/`File.cp_r` do not preserve the source's.
  defp capture_priv_baseline(path, mode) do
    path
    |> priv_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*"), match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn file -> {Path.relative_to(file, path), priv_fingerprint(file, mode)} end)
  end

  # Single-app: `priv/`. Umbrella: the root's own `priv/` (rare but harmless)
  # plus every child app's `<apps_path>/<app>/priv`.
  defp priv_dirs(root) do
    if Mut.Umbrella.umbrella?(root) do
      [root | Mut.Umbrella.app_dirs(root)]
    else
      [root]
    end
    |> Enum.map(&Path.join(&1, "priv"))
    |> Enum.filter(&File.dir?/1)
  end

  defp priv_fingerprint(file, :hash), do: sha256(file)
  defp priv_fingerprint(file, :stat), do: stat_fingerprint(file)

  defp priv_fingerprint_mode(opts) do
    case Keyword.get(opts, :priv_fingerprint, :stat) do
      mode when mode in [:stat, :hash] -> mode
      other -> raise ArgumentError, "invalid :priv_fingerprint #{inspect(other)}"
    end
  end

  # Test seam: lets a caller inject a copy that fails on the Nth sandbox so
  # partial-pool cleanup is exercised. Defaults to the real copy.
  defp copy_fun(opts) do
    case Keyword.get(opts, :copy_fun) do
      fun when is_function(fun, 2) -> fun
      nil -> &Mut.FileCopy.copy_tree/2
    end
  end

  # The recorded value decides the comparison: hex hash -> content,
  # `{:stat, size, mtime}` -> stat. Both return `nil` for a missing file.
  defp fingerprint(path, expected) when is_binary(expected), do: sha256(path)
  defp fingerprint(path, {:stat, _size, _mtime}), do: stat_fingerprint(path)

  defp stat_fingerprint(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} -> {:stat, size, mtime}
      _other -> nil
    end
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

  defp pool_path(run_id, root),
    do: Path.expand(Path.join([root, @sandbox_dir, run_id]))

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "schema-#{System.os_time(:second)}-#{random}"
  end
end
