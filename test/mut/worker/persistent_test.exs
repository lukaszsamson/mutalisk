defmodule Mut.Worker.PersistentTest do
  use ExUnit.Case, async: false

  alias Mut.Sandbox
  alias Mut.Worker.Persistent
  alias Mut.Worker.PersistentRunner

  @moduledoc false

  import ExUnit.CaptureLog

  @tag timeout: 30_000
  test "resets state created by the first mutant before later runs" do
    sandbox_path = fake_persistent_project("first_mutant_leak")
    sandbox = %Sandbox{id: 1, path: sandbox_path}

    {:ok, server} = Persistent.start_link(sandbox, test_files: ["test/leak_test.exs"])

    try do
      assert %{status: :killed} = Persistent.run_schema(server, 1, ["test/leak_test.exs"])
      assert %{status: :survived} = Persistent.run_schema(server, 2, ["test/leak_test.exs"])
    after
      stop(server)
    end
  end

  @tag timeout: 30_000
  test "records the first failing test for killed mutants" do
    sandbox_path = fake_persistent_project("killing_test")
    sandbox = %Sandbox{id: 1, path: sandbox_path}

    {:ok, server} = Persistent.start_link(sandbox, test_files: ["test/leak_test.exs"])

    try do
      result = Persistent.run_schema(server, 1, ["test/leak_test.exs"])

      assert result.status == :killed
      assert result.killing_test == "PersistentLeakTest no first-mutant ETS leak remains"
    after
      stop(server)
    end
  end

  @tag timeout: 30_000
  test "returns :filter_miss when selected files do not map to any loaded test" do
    sandbox_path = fake_persistent_project("filter_miss")
    sandbox = %Sandbox{id: 1, path: sandbox_path}

    {:ok, server} = Persistent.start_link(sandbox, test_files: ["test/leak_test.exs"])

    try do
      assert Persistent.run_schema(server, 0, ["test/missing_test.exs"]) == :filter_miss
    after
      stop(server)
    end
  end

  test "apply_file_filter rejects unknown files instead of running everything" do
    # Index has only one known test file; a request for an unrelated
    # file must surface as a filter_miss, NOT silently fall through to
    # "no filter" (which would run every loaded test).
    index = %{"/abs/known_test.exs" => [{KnownTest, :test_a}]}

    assert {:error, {:filter_miss, ["/abs/missing_test.exs"]}} =
             PersistentRunner.apply_file_filter(
               ["/abs/missing_test.exs"],
               index
             )
  end

  test "apply_file_filter accepts files that map through Path.expand" do
    abs = Path.expand("test/leak_test.exs")
    index = %{abs => [{LeakTest, :test_a}]}

    assert :ok =
             PersistentRunner.apply_file_filter(
               ["test/leak_test.exs"],
               index
             )
  end

  @tag timeout: 30_000
  test "exits during run when the worker BEAM crashes so callers can rerun through mix" do
    sandbox_path = fake_persistent_project("worker_crash")
    shim = crash_elixir_shim()

    {:ok, server} =
      Persistent.start_link(%Sandbox{id: 1, path: sandbox_path},
        elixir_path: shim,
        test_files: []
      )

    assert capture_log(fn ->
             assert catch_exit(Persistent.run_schema(server, 1, []))
           end) =~ "worker_crashed"
  end

  defp stop(server) do
    Persistent.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp fake_persistent_project(name) do
    root = Path.expand(Path.join(["tmp", "tests", "persistent", name]))
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), "defmodule PersistentFixture.MixProject do\nend\n")
    File.write!(Path.join(root, "test/test_helper.exs"), "")
    link_current_ebins(root)

    File.write!(
      Path.join(root, "test/leak_test.exs"),
      """
      defmodule PersistentLeakTest do
        use ExUnit.Case, async: false

        test "no first-mutant ETS leak remains" do
          if :persistent_term.get({Mut.Runtime, :active_mutant}, 0) == 1 do
            :ets.new(:_m19_first_mutant_leak, [:public, :named_table])
            flunk("first mutant intentionally leaks state")
          else
            assert :ets.whereis(:_m19_first_mutant_leak) == :undefined
          end
        end
      end
      """
    )

    root
  end

  defp link_current_ebins(root) do
    ebin_root = Path.join(root, "_build/mut_schema/lib")
    File.mkdir_p!(ebin_root)

    Path.wildcard(Path.expand("_build/test/lib/*/ebin"))
    |> Enum.each(fn source ->
      app = source |> Path.dirname() |> Path.basename()
      target_parent = Path.join(ebin_root, app)
      target = Path.join(target_parent, "ebin")

      File.mkdir_p!(target_parent)
      File.rm_rf!(target)
      File.ln_s!(source, target)
    end)
  end

  defp crash_elixir_shim do
    path = Path.expand(Path.join(["tmp", "tests", "persistent", "crash_elixir.sh"]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/usr/bin/env bash
    printf 'MUT_READY\n'
    IFS= read -r _line
    exit 99
    """)

    File.chmod!(path, 0o755)
    path
  end
end
