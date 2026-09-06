defmodule Mut.Sandbox do
  @moduledoc "Manages isolated worker sandboxes."

  @dialyzer {:no_opaque, checkin: 2, destroy_pool: 1}

  alias Mut.SchemaBuild

  defstruct [
    :id,
    :path,
    :baseline_snapshot,
    :baseline_source,
    :priv_baseline,
    source_extras: []
  ]

  @typedoc """
  A baseline entry describes one filesystem entry:

    * a regular file — a content hash (hex sha256) or a stat fingerprint
      `{:stat, size, mtime_posix}` (see `:priv_fingerprint`),
    * a symlink — `{:symlink, target}`, recorded with `File.read_link/1` and
      never followed,
    * a directory — `:directory` (so an EMPTY baseline directory is restored
      and a stray one is swept).

  The stored value decides which fingerprint is recomputed for the
  comparison, so every kind coexists in one baseline map.
  """
  @type fingerprint ::
          String.t() | {:stat, non_neg_integer, integer} | {:symlink, Path.t()} | :directory

  @type t :: %__MODULE__{
          id: pos_integer,
          path: Path.t(),
          baseline_snapshot: %{Path.t() => String.t()},
          baseline_source: Path.t(),
          priv_baseline: %{Path.t() => fingerprint} | nil,
          source_extras: [Path.t()]
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
  detected. Pass `priv_fingerprint: :hash` to `create_pool/3` (config key
  `priv_fingerprint`, flag `--priv-fingerprint`) for content-exact detection at
  full hashing cost. Restored `priv` files have their mtime reset to the
  recorded baseline value so the fingerprint is stable across resets.

  The baseline records EVERY entry type, not just regular files: symlinks (by
  target, read with `File.read_link/1` and never followed) and directories
  (including empty ones). So a reset also removes a directory or symlink a
  test created, recreates one it deleted, and re-points one it retargeted —
  all of which a `File.exists?`/`File.dir?`/`File.ls` in the next mutant's
  tests would otherwise observe (T26).

  ## Sources outside `lib/`

  The source baseline covers the `lib/` trees PLUS every distinct file named
  by the plan's `fallback` bucket, so a project compiling `src/` or `web/` via
  `elixirc_paths` still has every file a fallback run can patch restored and
  verified (W5-5). Those extra files are tracked individually (by content
  hash); their directories are NOT stray-swept, because they may hold
  untracked user files no baseline records. A test that CREATES a file under
  such a directory therefore leaks into the next mutant, exactly as it does
  under any other untracked directory.

  No root is ever traversed through a symlink: a `priv/` or `lib/` root that
  is (or becomes) a symlink is treated as an ENTRY — restored, retargeted or
  removed as a link — so a reset never deletes or writes through it (W5-1).
  """
  @spec reset(t) :: :ok | {:error, term}
  def reset(%__MODULE__{} = sandbox) do
    baseline = baseline(sandbox)
    :ok = restore_baseline_files(sandbox, baseline)
    :ok = remove_stray_files(sandbox, baseline)
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
    source_extras = source_extras(schema_result)

    Enum.reduce_while(1..concurrency, {:ok, []}, fn id, {:ok, sandboxes} ->
      path = Path.join(parent, Integer.to_string(id))

      with :ok <- copy_fun.(schema_result.work_copy_root, path),
           :ok <- assert_materialized(path) do
        sandbox = %__MODULE__{
          id: id,
          path: path,
          baseline_snapshot: schema_result.snapshot,
          baseline_source: schema_result.work_copy_root,
          priv_baseline: capture_priv_baseline(path, priv_mode),
          source_extras: source_extras
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
    # Directories first (parents before children): a baseline file whose
    # directory was replaced by a regular file can only be restored once that
    # directory is back.
    baseline
    |> Enum.sort_by(fn {relative, expected} -> {restore_order(expected), relative} end)
    |> Enum.each(fn {relative, expected} ->
      target = Path.join(sandbox.path, relative)

      if fingerprint(target, expected) != expected do
        File.mkdir_p!(Path.dirname(target))
        restore_entry(sandbox, relative, target, expected)
      end
    end)

    :ok
  end

  defp restore_order(:directory), do: 0
  defp restore_order(_expected), do: 1

  defp restore_entry(_sandbox, _relative, target, :directory) do
    File.rm_rf!(target)
    File.mkdir_p!(target)
    :ok
  end

  # `File.rm_rf!/1` on a symlink removes the LINK, never its target, so a
  # retargeted or clobbered link is replaced rather than written through.
  defp restore_entry(_sandbox, _relative, target, {:symlink, link_target}) do
    File.rm_rf!(target)
    :ok = File.ln_s(link_target, target)
  end

  defp restore_entry(sandbox, relative, target, expected) do
    source = Path.join(sandbox.baseline_source, relative)
    File.rm_rf!(target)
    :ok = Mut.FileCopy.copy_tree(source, target)
    restore_mtime(target, expected)
    :ok
  end

  # A fresh copy carries the copy's mtime, not the baseline's, so a stat
  # fingerprint would never converge. Stamp the recorded mtime back on.
  defp restore_mtime(target, {:stat, _size, mtime}), do: File.touch!(target, mtime)
  defp restore_mtime(_target, _expected), do: :ok

  defp remove_stray_files(sandbox, baseline_paths) do
    apps_dir = Mut.Umbrella.apps_path_name(sandbox.path)
    # Roots come from the TRACKED entries only: an extra fallback source
    # (`src/sample.ex`) must not turn its directory into a swept root.
    tracked_paths = Map.drop(baseline_paths, sandbox.source_extras)
    baseline_roots = baseline_roots(sandbox, tracked_paths, apps_dir)
    complete_roots = complete_roots(sandbox)

    sandbox.path
    |> all_entries()
    |> Enum.each(fn {path, type} ->
      relative = Path.relative_to(path, sandbox.path)
      root = path_root(relative, apps_dir)

      if Map.has_key?(baseline_roots, root) and not Map.has_key?(baseline_paths, relative) and
           sweepable?(type, Map.has_key?(complete_roots, root)) do
        remove_stray_entry(path, type)
      end
    end)

    :ok
  end

  # Only roots whose baseline records EVERY entry type — `priv/` and the
  # source `lib/` trees — may have stray DIRECTORIES and SYMLINKS swept. The
  # `_build/` snapshot lists regular files only, so a directory or link there
  # is not "stray" merely because the snapshot lacks it (sweeping those would
  # delete the build).
  defp sweepable?(:regular, _complete?), do: true
  defp sweepable?(_type, complete?), do: complete?

  defp remove_stray_entry(path, :directory) do
    File.rm_rf!(path)
    :ok
  end

  # A stray file/symlink may already be gone with a stray parent directory
  # removed earlier in the same walk. `File.rm!/1` on a symlink removes the
  # link, not its target.
  defp remove_stray_entry(path, _type) do
    case File.lstat(path) do
      {:ok, _stat} -> File.rm!(path)
      {:error, _reason} -> :ok
    end
  end

  # The cheap counterpart of `remove_stray_files/2`: walks only the `priv`
  # trees instead of the whole sandbox. The `priv` baseline is complete (files,
  # symlinks and directories), so every stray entry type is swept — including
  # the roots themselves, so a `priv` root a test created after checkout (a
  # directory, or a SYMLINK pointing outside the sandbox) is removed rather
  # than traversed (W5-1).
  defp remove_stray_priv_files(sandbox, baseline) do
    sandbox.path
    |> priv_roots()
    |> Enum.flat_map(&root_entries/1)
    |> Enum.each(fn {path, type} ->
      relative = Path.relative_to(path, sandbox.path)

      unless Map.has_key?(baseline, relative) do
        remove_stray_entry(path, type)
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

  # Walks `root` with `lstat` (symlinks are NEVER followed) and returns every
  # entry as `{path, :regular | :symlink | :directory}` — directories and empty
  # directories included, so a baseline can record, and a sweep can remove,
  # entries of every type (T26). Other types (devices, fifos) are ignored.
  defp all_entries(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(root, entry)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> [{path, :directory} | all_entries(path)]
        {:ok, %File.Stat{type: :symlink}} -> [{path, :symlink}]
        {:ok, %File.Stat{type: :regular}} -> [{path, :regular}]
        {:ok, _stat} -> []
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
    |> Map.merge(sandbox_priv_roots(sandbox))
  end

  defp sandbox_priv_roots(sandbox), do: relative_roots(sandbox, priv_roots(sandbox.path))

  # Roots whose baseline records every entry type: `priv/` (captured by the
  # lstat walker) and the source `lib/` trees (same walker, see
  # `source_baseline/1`).
  defp complete_roots(sandbox) do
    sandbox
    |> relative_roots(source_roots(sandbox.path))
    |> Map.merge(sandbox_priv_roots(sandbox))
  end

  defp relative_roots(sandbox, roots),
    do: Map.new(roots, &{relative_root(&1, sandbox.path), true})

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

  # The tracked ROOTS (`_build/mut_schema`, the `lib` trees, `priv`) plus the
  # individually tracked extra fallback sources, which define no root of their
  # own so their directories are never stray-swept (see `source_extras/1`).
  defp baseline(sandbox) do
    sandbox.baseline_snapshot
    |> Enum.into(%{}, fn {relative, hash} -> {Path.join("_build/mut_schema", relative), hash} end)
    |> Map.merge(source_baseline(sandbox.baseline_source))
    |> Map.merge(sandbox.priv_baseline || %{})
    |> Map.merge(extra_source_baseline(sandbox))
  end

  # The `priv` baseline is captured from the sandbox itself at creation (the
  # copy is byte-identical to `baseline_source`, which is where restores come
  # from) because a stat fingerprint is only meaningful against the mtimes the
  # copy actually produced — `cp`/`File.cp_r` do not preserve the source's.
  defp capture_priv_baseline(path, mode) do
    # Same lstat walker as the stray sweep: `Path.wildcard/2` would follow a
    # symlinked directory (`priv/static -> ../../assets`) and record baseline
    # entries whose real target lives OUTSIDE the sandbox, which a restore
    # would then write through.
    roots = priv_roots(path)

    roots
    |> Enum.flat_map(&root_entries/1)
    |> Map.new(fn {entry, type} ->
      {Path.relative_to(entry, path), entry_fingerprint(entry, type, mode)}
    end)
  end

  # Single-app: `priv/`. Umbrella: the root's own `priv/` (rare but harmless)
  # plus every child app's `<apps_path>/<app>/priv`.
  defp priv_candidates(root) do
    if Mut.Umbrella.umbrella?(root) do
      [root | Mut.Umbrella.app_dirs(root)]
    else
      [root]
    end
    |> Enum.map(&Path.join(&1, "priv"))
  end

  # W5-1 (data loss): roots were selected with `File.dir?/1`, which FOLLOWS
  # symlinks, and `all_entries/1` then called `File.ls!` on the root itself.
  # A `priv` root created as a symlink AFTER checkout (a test doing
  # `ln_s "/somewhere/real", "priv"`) was therefore traversed and its target's
  # files — outside the sandbox entirely — were deleted as strays, since the
  # baseline of a root that did not exist at creation time cannot protect them.
  #
  # Every candidate root is now classified with `lstat`: a symlink root is an
  # ENTRY (compared against the baseline as `{:symlink, target}`, swept as a
  # stray LINK when absent from it, and restored/retargeted by the baseline),
  # never a directory to walk into. Nothing is ever deleted or written through
  # a symlink.
  defp source_roots(root), do: root |> source_candidates() |> classify_roots()

  defp priv_roots(root), do: root |> priv_candidates() |> classify_roots()

  defp classify_roots(candidates) do
    Enum.flat_map(candidates, fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> [{path, :directory}]
        {:ok, %File.Stat{type: :symlink}} -> [{path, :symlink}]
        _other -> []
      end
    end)
  end

  # A root and everything under it. The root is listed FIRST (so a stray root
  # is removed before its descendants are visited) and a symlink root yields
  # only itself — it is never enumerated.
  defp root_entries({root, :symlink}), do: [{root, :symlink}]
  defp root_entries({root, :directory}), do: [{root, :directory} | all_entries(root)]

  defp entry_fingerprint(_entry, :directory, _mode), do: :directory
  defp entry_fingerprint(entry, :symlink, _mode), do: link_fingerprint(entry)
  defp entry_fingerprint(entry, :regular, mode), do: priv_fingerprint(entry, mode)

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
  # `{:stat, size, mtime}` -> stat, `{:symlink, target}` -> link target,
  # `:directory` -> directory presence. All return `nil` for a missing entry
  # (or one whose TYPE changed), which never equals the recorded value, so the
  # entry is restored.
  defp fingerprint(path, expected) when is_binary(expected), do: sha256(path)
  defp fingerprint(path, {:stat, _size, _mtime}), do: stat_fingerprint(path)
  defp fingerprint(path, {:symlink, _target}), do: link_fingerprint(path)
  defp fingerprint(path, :directory), do: directory_fingerprint(path)

  # `File.lstat/2`, never `File.stat/2` (W4-3): a baseline file replaced by a
  # symlink must read as a mismatch, not as the link target's stat — otherwise
  # the restore would write THROUGH the link, outside the sandbox.
  defp stat_fingerprint(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} -> {:stat, size, mtime}
      _other -> nil
    end
  end

  defp link_fingerprint(path) do
    case File.read_link(path) do
      {:ok, target} -> {:symlink, target}
      {:error, _reason} -> nil
    end
  end

  defp directory_fingerprint(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :directory
      _other -> nil
    end
  end

  # Same lstat walker as `priv/`: every entry type is recorded (regular files by
  # content hash, symlinks by target, directories by presence) so the source
  # sweep can remove a stray directory or symlink a test created under `lib/`
  # without mistaking a baseline one for a stray (T26).
  defp source_baseline(baseline_source) do
    baseline_source
    |> source_roots()
    |> Enum.flat_map(&root_entries/1)
    |> Map.new(fn {entry, type} ->
      {Path.relative_to(entry, baseline_source), entry_fingerprint(entry, type, :hash)}
    end)
  end

  # Single-app: the project's own lib/. Umbrella: every child app's lib/, so a
  # fallback-patched source file under apps/<app>/lib resets between mutants
  # (the umbrella root has no lib/ of its own). M68.
  defp source_candidates(root) do
    if Mut.Umbrella.umbrella?(root) do
      root
      |> Mut.Umbrella.app_dirs()
      |> Enum.map(&Path.join(&1, "lib"))
    else
      [Path.join(root, "lib")]
    end
  end

  # W5-5: `source_candidates/1` hardcodes `lib/`, but a project may compile any
  # directory via `elixirc_paths` (`["src"]`, `["lib", "web"]`) and `--files`
  # may select those `.ex` files, which `Mut.Worker.run_fallback/4` then
  # PATCHES in the sandbox. Those files were absent from the source baseline,
  # so `reset/1` neither restored nor verified them and the next mutant
  # compiled the previous mutation too (and, once a replacement changed the
  # byte length, addressed the wrong source span).
  #
  # `elixirc_paths` is deliberately NOT parsed: it is nearly always a private
  # function branching on `Mix.env()`, so its value cannot be read statically.
  # Instead the baseline covers the union of the `lib` roots and every distinct
  # file named by `plan.fallback` — precisely the set a fallback run can patch.
  #
  # Trade-off: extra files are tracked INDIVIDUALLY (restored and verified by
  # content hash) and their directories are NOT stray-swept. `src/` may hold
  # untracked user files that no baseline records, and sweeping the root would
  # delete them; a fallback run only rewrites files it patches, so restoring
  # them is sufficient. A test that CREATES a file under such a root therefore
  # leaks into the next mutant, exactly as it does under any other untracked
  # directory (`config/`, the project root).
  defp source_extras(%SchemaBuild.Result{} = schema_result) do
    root = schema_result.work_copy_root
    tracked_roots = Enum.map(source_roots(root) ++ priv_roots(root), &relative_root(&1, root))

    schema_result.plan.fallback
    |> Enum.map(& &1.file)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.uniq()
    |> Enum.reject(fn relative -> Enum.any?(tracked_roots, &under_root?(relative, &1)) end)
    |> Enum.filter(&regular?(Path.join(root, &1)))
    |> Enum.sort()
  end

  defp relative_root({path, _type}, root), do: Path.relative_to(path, root)

  defp under_root?(relative, root),
    do: relative == root or String.starts_with?(relative, root <> "/")

  # Hashed from the pristine `baseline_source` (the work copy is never patched;
  # only its sandbox copies are), so a restore reproduces the original bytes.
  defp extra_source_baseline(sandbox) do
    sandbox.source_extras
    |> Enum.map(fn relative ->
      {relative, sha256(Path.join(sandbox.baseline_source, relative))}
    end)
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Map.new()
  end

  defp sha256(path) do
    if regular?(path) do
      :sha256
      |> :crypto.hash(File.read!(path))
      |> Base.encode16(case: :lower)
    end
  end

  # `File.regular?/1` follows symlinks; the baseline comparison must not.
  defp regular?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  defp pool_path(run_id, root),
    do: Path.expand(Path.join([root, @sandbox_dir, run_id]))

  defp run_id do
    random = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "schema-#{System.os_time(:second)}-#{random}"
  end
end
