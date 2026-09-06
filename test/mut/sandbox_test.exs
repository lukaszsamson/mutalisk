defmodule Mut.SandboxTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Sandbox
  alias Mut.SchemaBuild

  test "create_pool copies schema work copy and preserves symlinks" do
    schema_result = schema_result("create_pool")

    assert {:ok, pool} =
             Sandbox.create_pool(schema_result, 2, run_id: "unit-sandbox-pool", force: true)

    paths = pool.sandboxes |> Enum.map(& &1.path) |> Enum.sort()
    assert length(paths) == 2
    assert Enum.all?(paths, &File.dir?/1)
    assert Enum.all?(paths, &File.dir?(Path.join(&1, "_build/mut_schema")))
    assert Enum.all?(paths, &File.exists?(Path.join(&1, "mix.exs")))

    assert Enum.all?(
             paths,
             &match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(&1, "deps")))
           )

    assert :ok = Sandbox.destroy_pool(pool)
    refute File.exists?(Path.expand("tmp/mut_sandboxes/unit-sandbox-pool"))
  end

  test "checkout and checkin move sandboxes between pool sets" do
    schema_result = schema_result("checkout")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-checkout", force: true)

    assert {:ok, sandbox, pool} = Sandbox.checkout(pool)
    assert MapSet.member?(pool.checked_out, sandbox)
    assert {:error, :pool_empty} = Sandbox.checkout(pool)

    checked_in = Sandbox.checkin(sandbox, pool)
    assert MapSet.member?(checked_in.sandboxes, sandbox)
    refute MapSet.member?(checked_in.checked_out, sandbox)

    assert checked_in == Sandbox.checkin(sandbox, checked_in)
    Sandbox.destroy_pool(checked_in)
  end

  test "create_pool fails loudly when sandbox materialization is incomplete" do
    schema_result = schema_result("bad_materialization")
    File.rm!(Path.join(schema_result.work_copy_root, "mix.exs"))

    assert {:error, {:missing_mix_exs, path}} =
             Sandbox.create_pool(schema_result, 1,
               run_id: "unit-sandbox-bad-materialization",
               force: true
             )

    assert path =~ "unit-sandbox-bad-materialization/1"
  end

  test "reset restores corrupted baseline and source files and removes stray files" do
    schema_result = schema_result("reset")
    {:ok, pool} = Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-reset", force: true)
    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    baseline_file =
      Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")

    File.write!(baseline_file, "corrupt")
    source_file = Path.join(sandbox.path, "lib/arith.ex")
    File.write!(source_file, "corrupt source")

    File.write!(
      Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/stray.beam"),
      "stray"
    )

    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(baseline_file) == "beam"
    assert File.read!(source_file) == "defmodule Arith, do: :ok\n"
    refute File.exists?(Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/stray.beam"))

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "8 concurrent workers checkout/touch/reset/checkin without interference" do
    schema_result = schema_result("concurrent")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 8,
        run_id: "unit-sandbox-concurrent",
        force: true
      )

    {:ok, queue} = Mut.SandboxQueue.start_link(pool)
    iterations = 32

    tasks =
      for i <- 1..iterations do
        Task.async(fn ->
          {:ok, sandbox} = Mut.SandboxQueue.checkout(queue)

          try do
            # Simulate a worker run by writing a unique stray + dirtying a tracked file.
            stray = Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/stray_#{i}.beam")
            File.write!(stray, "stray-#{i}")

            tracked =
              Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")

            File.write!(tracked, "corrupt-#{i}")

            assert :ok = Sandbox.reset(sandbox)
            refute File.exists?(stray)
            assert File.read!(tracked) == "beam"
            sandbox.path
          after
            Mut.SandboxQueue.checkin(queue, sandbox)
          end
        end)
      end

    paths_touched = Task.await_many(tasks, 60_000)
    assert length(paths_touched) == iterations
    # Every task must have observed exactly one of the 8 sandbox paths.
    distinct = paths_touched |> MapSet.new() |> MapSet.size()
    assert distinct <= 8

    final_pool = Mut.SandboxQueue.finalize(queue)
    assert MapSet.size(final_pool.checked_out) == 0
    assert MapSet.size(final_pool.sandboxes) == 8
    Sandbox.destroy_pool(final_pool)
  end

  test "reset restores test-written priv/ state (T26)" do
    schema_result = schema_result("priv")
    File.mkdir_p!(Path.join(schema_result.work_copy_root, "priv/repo"))
    File.write!(Path.join(schema_result.work_copy_root, "priv/repo/seed.sql"), "seed\n")

    {:ok, pool} = Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv", force: true)
    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    seed = Path.join(sandbox.path, "priv/repo/seed.sql")
    assert File.read!(seed) == "seed\n"

    # A test writing under priv/: a new database plus a mutated baseline file.
    db = Path.join(sandbox.path, "priv/repo/app.db")
    File.write!(db, "sqlite-bytes")
    File.write!(seed, "clobbered by mutant A\n")

    assert :ok = Sandbox.reset(sandbox)
    refute File.exists?(db)
    assert File.read!(seed) == "seed\n"

    # Reset is idempotent: the restored file's fingerprint matches the baseline
    # again (the stat baseline's mtime is stamped back on).
    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(seed) == "seed\n"

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "reset_priv restores priv/ for schema workers without touching the build (T26)" do
    schema_result = schema_result("priv_only")
    File.mkdir_p!(Path.join(schema_result.work_copy_root, "priv"))
    File.write!(Path.join(schema_result.work_copy_root, "priv/asset.txt"), "asset\n")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-only", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    asset = Path.join(sandbox.path, "priv/asset.txt")
    stray = Path.join(sandbox.path, "priv/mnesia.DCD")
    File.write!(asset, "clobbered\n")
    File.write!(stray, "mnesia")

    # A beam left dirty by something else is NOT this call's business.
    beam = Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")
    File.write!(beam, "dirty")

    assert :ok = Sandbox.reset_priv(sandbox)
    assert File.read!(asset) == "asset\n"
    refute File.exists?(stray)
    assert File.read!(beam) == "dirty"

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "priv_fingerprint: :hash detects same-size same-second rewrites (T26)" do
    schema_result = schema_result("priv_hash")
    File.mkdir_p!(Path.join(schema_result.work_copy_root, "priv"))
    File.write!(Path.join(schema_result.work_copy_root, "priv/asset.txt"), "aaaa")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1,
        run_id: "unit-sandbox-priv-hash",
        force: true,
        priv_fingerprint: :hash
      )

    {:ok, sandbox, pool} = Sandbox.checkout(pool)
    asset = Path.join(sandbox.path, "priv/asset.txt")

    # Same size, and forced back to the original mtime: only a content hash
    # can see this.
    {:ok, %File.Stat{mtime: mtime}} = File.stat(asset, time: :posix)
    File.write!(asset, "bbbb")
    File.touch!(asset, mtime)

    assert :ok = Sandbox.reset_priv(sandbox)
    assert File.read!(asset) == "aaaa"

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "reset_priv removes stray priv/ directories and symlinks (T26)" do
    schema_result = schema_result("priv_entries")
    File.mkdir_p!(Path.join(schema_result.work_copy_root, "priv"))
    File.write!(Path.join(schema_result.work_copy_root, "priv/asset.txt"), "asset\n")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-entries", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    # A test creating an EMPTY directory, a nested directory holding a file,
    # and a symlink under priv/.
    empty_dir = Path.join(sandbox.path, "priv/cache")
    nested_file = Path.join(sandbox.path, "priv/nested/deep/app.db")
    link = Path.join(sandbox.path, "priv/link.txt")
    outside = Path.join(sandbox.path, "outside.txt")
    File.write!(outside, "outside\n")
    File.mkdir_p!(empty_dir)
    File.mkdir_p!(Path.dirname(nested_file))
    File.write!(nested_file, "sqlite-bytes")
    :ok = File.ln_s(outside, link)

    assert :ok = Sandbox.reset_priv(sandbox)

    refute File.exists?(empty_dir)
    refute File.exists?(Path.join(sandbox.path, "priv/nested"))
    refute File.exists?(link)
    # The symlink is removed, never followed: its target is untouched.
    assert File.read!(outside) == "outside\n"
    assert File.read!(Path.join(sandbox.path, "priv/asset.txt")) == "asset\n"

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "reset_priv restores deleted, retargeted and removed baseline priv/ entries (T26)" do
    schema_result = schema_result("priv_restore")
    work_copy = schema_result.work_copy_root
    File.mkdir_p!(Path.join(work_copy, "priv/empty"))
    File.write!(Path.join(work_copy, "priv/asset.txt"), "asset\n")
    File.write!(Path.join(work_copy, "priv/other.txt"), "other\n")
    :ok = File.ln_s("asset.txt", Path.join(work_copy, "priv/current.txt"))

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-restore", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    link = Path.join(sandbox.path, "priv/current.txt")
    empty = Path.join(sandbox.path, "priv/empty")
    assert {:ok, "asset.txt"} = File.read_link(link)

    # A test deletes the baseline symlink and the baseline (empty) directory.
    File.rm!(link)
    File.rm_rf!(empty)

    assert :ok = Sandbox.reset_priv(sandbox)
    assert {:ok, "asset.txt"} = File.read_link(link)
    assert File.dir?(empty)

    # A test retargets the baseline symlink.
    File.rm!(link)
    :ok = File.ln_s("other.txt", link)
    assert :ok = Sandbox.reset_priv(sandbox)
    assert {:ok, "asset.txt"} = File.read_link(link)

    # Restoring never writes THROUGH the link: both targets keep their bytes.
    assert File.read!(Path.join(sandbox.path, "priv/asset.txt")) == "asset\n"
    assert File.read!(Path.join(sandbox.path, "priv/other.txt")) == "other\n"

    # Idempotent: a second reset finds nothing to do.
    assert :ok = Sandbox.reset_priv(sandbox)

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "reset restores a deleted priv/ tree and sweeps stray lib/ entries (T26)" do
    schema_result = schema_result("priv_tree")
    File.mkdir_p!(Path.join(schema_result.work_copy_root, "priv/repo"))
    File.write!(Path.join(schema_result.work_copy_root, "priv/repo/seed.sql"), "seed\n")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-tree", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    # The whole priv/ tree is deleted by a test...
    File.rm_rf!(Path.join(sandbox.path, "priv"))
    # ...and a stray directory plus a stray symlink appear under lib/.
    stray_dir = Path.join(sandbox.path, "lib/generated")
    stray_link = Path.join(sandbox.path, "lib/alias.ex")
    File.mkdir_p!(stray_dir)
    File.write!(Path.join(stray_dir, "gen.ex"), "# generated\n")
    :ok = File.ln_s("arith.ex", stray_link)

    assert :ok = Sandbox.reset(sandbox)

    assert File.dir?(Path.join(sandbox.path, "priv/repo"))
    assert File.read!(Path.join(sandbox.path, "priv/repo/seed.sql")) == "seed\n"
    refute File.exists?(stray_dir)
    refute File.exists?(stray_link)
    assert File.read!(Path.join(sandbox.path, "lib/arith.ex")) == "defmodule Arith, do: :ok\n"
    # The build tree is untouched by the source sweep.
    assert File.exists?(
             Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")
           )

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "reset sweeps umbrella apps/<app>/priv (T26)" do
    schema_result = umbrella_schema_result("umbrella_priv")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-umbrella-priv", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    seed = Path.join(sandbox.path, "apps/child/priv/seed.sql")
    assert File.read!(seed) == "seed\n"

    stray = Path.join(sandbox.path, "apps/child/priv/repo/app.db")
    File.mkdir_p!(Path.dirname(stray))
    File.write!(stray, "sqlite-bytes")
    File.write!(seed, "clobbered\n")

    # An untracked sibling root under apps/<app> must survive the sweep.
    keep = Path.join(sandbox.path, "apps/child/test/child_test.exs")
    assert File.exists?(keep)

    assert :ok = Sandbox.reset(sandbox)
    refute File.exists?(stray)
    assert File.read!(seed) == "seed\n"
    assert File.exists?(keep)

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
  end

  test "create_pool removes the partial pool when a sandbox fails (T28)" do
    schema_result = schema_result("partial")

    # Fail on the third of three sandboxes; the first two are fully created.
    copy_fun = fn source, destination ->
      if Path.basename(destination) == "3" do
        {:error, :injected_copy_failure}
      else
        Mut.FileCopy.copy_tree(source, destination)
      end
    end

    parent = Path.expand("tmp/mut_sandboxes/unit-sandbox-partial")

    assert {:error, :injected_copy_failure} =
             Sandbox.create_pool(schema_result, 3,
               run_id: "unit-sandbox-partial",
               force: true,
               copy_fun: copy_fun
             )

    refute File.exists?(Path.join(parent, "1"))
    refute File.exists?(Path.join(parent, "2"))
    refute File.exists?(parent)
  end

  test "a priv/ root that is itself a symlink is restored as a link, not a directory" do
    schema_result = schema_result("priv_symlink_root")
    work_copy = schema_result.work_copy_root
    File.mkdir_p!(Path.join(work_copy, "shared_priv"))
    File.write!(Path.join(work_copy, "shared_priv/asset.txt"), "asset\n")
    :ok = File.ln_s("shared_priv", Path.join(work_copy, "priv"))

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-symroot", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)
    priv = Path.join(sandbox.path, "priv")

    case File.read_link(priv) do
      {:ok, "shared_priv"} ->
        assert :ok = Sandbox.reset_priv(sandbox)
        assert {:ok, "shared_priv"} = File.read_link(priv), "reset replaced the priv link"
        assert :ok = Sandbox.reset(sandbox)
        assert {:ok, "shared_priv"} = File.read_link(priv), "reset replaced the priv link"

      _copied_as_dir ->
        # The copy step dereferenced the link; nothing to protect here.
        assert :ok = Sandbox.reset_priv(sandbox)
    end

    Sandbox.destroy_pool(Sandbox.checkin(sandbox, pool))
  end

  test "reset_priv never follows a priv root symlink created after checkout (P1)" do
    schema_result = schema_result("priv_new_symlink_root")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-priv-new-symroot", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    external =
      Path.expand(Path.join(["tmp", "tests", "sandbox", "priv_new_symlink_root", "external"]))

    File.mkdir_p!(external)
    keep = Path.join(external, "keep.txt")
    File.write!(keep, "keep\n")

    priv = Path.join(sandbox.path, "priv")
    assert {:error, :enoent} = File.lstat(priv)
    :ok = File.ln_s(external, priv)

    assert :ok = Sandbox.reset_priv(sandbox)
    assert File.regular?(keep), "reset_priv deleted a file through a symlinked priv root"
    assert {:error, :enoent} = File.lstat(priv), "the stray priv link was not swept"

    :ok = File.ln_s(external, priv)
    assert :ok = Sandbox.reset(sandbox)
    assert File.regular?(keep), "reset deleted a file through a symlinked priv root"
    assert {:error, :enoent} = File.lstat(priv), "the stray priv link was not swept"

    Sandbox.destroy_pool(Sandbox.checkin(sandbox, pool))
  end

  test "reset_priv never follows an umbrella child priv root symlink (P1)" do
    schema_result = umbrella_schema_result("umbrella_priv_new_symlink_root")
    File.rm_rf!(Path.join(schema_result.work_copy_root, "apps/child/priv"))

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1,
        run_id: "unit-sandbox-umbrella-priv-new-symroot",
        force: true
      )

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    external =
      Path.expand(
        Path.join(["tmp", "tests", "sandbox", "umbrella_priv_new_symlink_root", "external"])
      )

    File.mkdir_p!(external)
    keep = Path.join(external, "keep.txt")
    File.write!(keep, "keep\n")

    priv = Path.join(sandbox.path, "apps/child/priv")
    assert {:error, :enoent} = File.lstat(priv)
    :ok = File.ln_s(external, priv)

    assert :ok = Sandbox.reset_priv(sandbox)
    assert File.regular?(keep), "reset_priv deleted a file through a symlinked priv root"
    assert {:error, :enoent} = File.lstat(priv), "the stray priv link was not swept"

    Sandbox.destroy_pool(Sandbox.checkin(sandbox, pool))
  end

  test "reset restores fallback sources outside lib/ (P1)" do
    schema_result = schema_result("src_fallback")
    work_copy = schema_result.work_copy_root
    File.mkdir_p!(Path.join(work_copy, "src"))
    original = "defmodule Sample, do: :ok\n"
    File.write!(Path.join(work_copy, "src/sample.ex"), original)

    schema_result = %{
      schema_result
      | plan: %Mut.Plan{
          schema: [],
          skipped: [],
          fallback: [fallback_mutant("src/sample.ex")]
        }
    }

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "unit-sandbox-src-fallback", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    patched = Path.join(sandbox.path, "src/sample.ex")
    File.write!(patched, "defmodule Sample, do: :mutated\n")
    untracked = Path.join(sandbox.path, "src/untracked.txt")
    File.write!(untracked, "keep\n")

    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(patched) == original, "a fallback source outside lib/ was not restored"

    assert File.read!(untracked) == "keep\n",
           "the extra source's directory must not be stray-swept"

    Sandbox.destroy_pool(Sandbox.checkin(sandbox, pool))
  end

  defp fallback_mutant(file) do
    %Mut.Mutant{
      id: 1,
      stable_id: "fallback-#{file}",
      engine: :fallback,
      mutator: Mut.Mutator.IntegerLiteral,
      mutator_name: "integer_literal",
      file: file,
      line: 1,
      original_ast: nil,
      mutated_ast: nil,
      description: "test fixture"
    }
  end

  defp umbrella_schema_result(name) do
    root = Path.expand(Path.join(["tmp", "tests", "sandbox", name, "schema"]))
    File.rm_rf!(Path.dirname(root))
    app = Path.join(root, "apps/child")
    File.mkdir_p!(Path.join(app, "lib"))
    File.mkdir_p!(Path.join(app, "priv"))
    File.mkdir_p!(Path.join(app, "test"))
    File.mkdir_p!(Path.join(root, "_build/mut_schema/lib/child/ebin"))

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Umb.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: \"apps\"]\nend\n"
    )

    File.write!(
      Path.join(app, "mix.exs"),
      "defmodule Child.MixProject do\n  use Mix.Project\n  def project, do: [app: :child, version: \"0.1.0\"]\nend\n"
    )

    File.write!(Path.join(app, "lib/child.ex"), "defmodule Child, do: :ok\n")
    File.write!(Path.join(app, "priv/seed.sql"), "seed\n")
    File.write!(Path.join(app, "test/child_test.exs"), "# test\n")
    File.write!(Path.join(root, "_build/mut_schema/lib/child/ebin/Elixir.Child.beam"), "beam")

    %SchemaBuild.Result{
      work_copy_root: root,
      build_path: Path.join(root, "_build/mut_schema"),
      plan: %Mut.Plan{schema: [], fallback: [], skipped: []},
      placement_maps: %{},
      snapshot: %{
        "lib/child/ebin/Elixir.Child.beam" =>
          sha256(Path.join(root, "_build/mut_schema/lib/child/ebin/Elixir.Child.beam"))
      },
      rollback_iterations: 0,
      invalid_mutants: []
    }
  end

  defp schema_result(name) do
    root = Path.expand(Path.join(["tmp", "tests", "sandbox", name, "schema"]))
    File.rm_rf!(Path.dirname(root))
    File.mkdir_p!(Path.join(root, "_build/mut_schema/lib/demo_app/ebin"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "deps_target"))
    File.write!(Path.join(root, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"), "beam")
    File.write!(Path.join(root, "lib/arith.ex"), "defmodule Arith, do: :ok\n")
    File.write!(Path.join(root, "mix.exs"), "mix")
    :ok = File.ln_s(Path.join(root, "deps_target"), Path.join(root, "deps"))

    %SchemaBuild.Result{
      work_copy_root: root,
      build_path: Path.join(root, "_build/mut_schema"),
      plan: %Mut.Plan{schema: [], fallback: [], skipped: []},
      placement_maps: %{},
      snapshot: %{
        "lib/demo_app/ebin/Elixir.Arith.beam" =>
          sha256(Path.join(root, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"))
      },
      rollback_iterations: 0,
      invalid_mutants: []
    }
  end

  defp sha256(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end
end
