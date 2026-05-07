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
  test "auto-restarts the BEAM after a crash and replies :crashed for the failing mutant" do
    # F4 auto-restart: the worker BEAM crashes mid-run. The host
    # rebuilds the port in-place rather than tearing the GenServer
    # down. The current mutant gets `:crashed` (so the caller can
    # rerun via mix); the GenServer stays alive for subsequent
    # mutants on the same sandbox.
    sandbox_path = fake_persistent_project("worker_crash")
    shim = crash_elixir_shim()

    {:ok, server} =
      Persistent.start_link(%Sandbox{id: 1, path: sandbox_path},
        elixir_path: shim,
        test_files: []
      )

    try do
      assert Persistent.run_schema(server, 1, []) == :crashed
      assert Process.alive?(server)
      # The shim always crashes; second call also returns :crashed,
      # confirming the restart succeeded between calls.
      assert Persistent.run_schema(server, 2, []) == :crashed
    after
      stop(server)
    end
  end

  @tag timeout: 30_000
  test "replies :timeout (not :crashed) when host deadline expires mid-run" do
    # M20 Phase B.1: distinguish timeout from crash. A run that
    # exceeds `timeout_ms` is a host-side deadline expiry, not a
    # BEAM crash. The persistent BEAM is still rebooted (so the
    # rest of this sandbox's mutants stay on persistent), but the
    # caller does NOT mix-spawn retry — the mutant outcome is
    # Timeout and a mix retry would just timeout again.
    sandbox_path = fake_persistent_project("worker_timeout")
    shim = silent_elixir_shim()

    {:ok, server} =
      Persistent.start_link(%Sandbox{id: 1, path: sandbox_path},
        elixir_path: shim,
        test_files: []
      )

    try do
      # Tight timeout — the shim writes MUT_READY then never
      # responds, so RUN waits the full deadline before reporting
      # back as :timeout.
      assert Persistent.run_schema(server, 1, [], timeout_ms: 200) == :timeout
      assert Process.alive?(server)
    after
      stop(server)
    end
  end

  @tag timeout: 30_000
  test "stops the GenServer when restart itself fails" do
    # If boot of the replacement BEAM fails (port not spawnable,
    # boot timeout), the GenServer stops with :worker_crashed and
    # the caller's :exit catch in Mix.Tasks.Mut routes every
    # subsequent mutant on this sandbox via the mix-spawn worker.
    sandbox_path = fake_persistent_project("worker_crash_unrestartable")
    shim = crash_elixir_shim()

    {:ok, server} =
      Persistent.start_link(%Sandbox{id: 1, path: sandbox_path},
        elixir_path: shim,
        test_files: []
      )

    # Replace the shim with a non-existent path between start_link
    # and the run, so the auto-restart's open_port fails.
    File.rm!(shim)

    assert capture_log(fn ->
             assert Persistent.run_schema(server, 1, []) == :crashed
             :timer.sleep(50)
             refute Process.alive?(server)
           end) =~ "worker_crashed"
  end

  @tag timeout: 30_000
  test "run_fallback compiles patched source in-process and restores original on success" do
    # M21 in-process fallback: persistent BEAM compiles a patched
    # source file via Code.compile_file/1, runs the test against the
    # patched module, then restores the original via :code.load_file.
    # No mix-spawn, no mix test child process.
    sandbox_path = fake_fallback_project("inprocess_basic")
    sandbox = %Sandbox{id: 1, path: sandbox_path}

    {:ok, server} = Persistent.start_link(sandbox, test_files: ["test/calc_test.exs"])

    try do
      # Pre-condition: original module was loaded; tests pass.
      result =
        Persistent.run_fallback(
          server,
          0,
          [],
          ["test/calc_test.exs"]
        )

      assert %{status: :survived} = result

      # Now write a "patched" source that breaks the test, ask the
      # runner to recompile in-process and run.
      File.write!(
        Path.join(sandbox_path, "lib/calc.ex"),
        """
        defmodule Calc do
          def add(a, b), do: a - b
        end
        """
      )

      result =
        Persistent.run_fallback(
          server,
          1,
          ["lib/calc.ex"],
          ["test/calc_test.exs"]
        )

      assert %{status: :killed} = result

      # Restore the original source (mirrors Mut.Worker.run_fallback_in_process's
      # Sandbox.reset/1 in the `after` clause). The runner has already
      # restored the ORIGINAL module via :code.load_file, so the next
      # run with the original test should pass.
      File.write!(
        Path.join(sandbox_path, "lib/calc.ex"),
        """
        defmodule Calc do
          def add(a, b), do: a + b
        end
        """
      )

      result =
        Persistent.run_fallback(
          server,
          0,
          [],
          ["test/calc_test.exs"]
        )

      assert %{status: :survived} = result
    after
      stop(server)
    end
  end

  @tag timeout: 30_000
  test "run_fallback returns :compile_error when the patched source has a syntax error" do
    sandbox_path = fake_fallback_project("inprocess_syntax")
    sandbox = %Sandbox{id: 1, path: sandbox_path}

    {:ok, server} = Persistent.start_link(sandbox, test_files: ["test/calc_test.exs"])

    try do
      File.write!(
        Path.join(sandbox_path, "lib/calc.ex"),
        "defmodule Calc do def add(a, b) :: a + b end\n"
      )

      reply =
        Persistent.run_fallback(
          server,
          1,
          ["lib/calc.ex"],
          ["test/calc_test.exs"]
        )

      assert {:compile_error, _category, _message} = reply
      assert Process.alive?(server)
    after
      stop(server)
    end
  end

  defp stop(server) do
    Persistent.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp fake_fallback_project(name) do
    root = Path.expand(Path.join(["tmp", "tests", "persistent", name]))
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), "defmodule FallbackFixture.MixProject do\nend\n")
    File.write!(Path.join(root, "test/test_helper.exs"), "")
    link_current_ebins(root)

    # Write the original module + a corresponding ebin so :code.load_file
    # has something to restore from. The schema-build path used by
    # `-pa _build/mut_schema/lib/*/ebin` is materialised by writing the
    # compiled .beam alongside.
    File.write!(
      Path.join(root, "lib/calc.ex"),
      """
      defmodule Calc do
        def add(a, b), do: a + b
      end
      """
    )

    [{Calc, beam}] =
      Code.compile_string("defmodule Calc do def add(a, b), do: a + b end")

    ebin = Path.join([root, "_build", "mut_schema", "lib", "fallback_fixture", "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "Elixir.Calc.beam"), beam)

    # Ensure the test process unloads Calc so it doesn't pollute the
    # fixture between runs.
    :code.purge(Calc)
    :code.delete(Calc)

    File.write!(
      Path.join(root, "test/calc_test.exs"),
      """
      defmodule CalcTest do
        use ExUnit.Case, async: false

        test "add/2 adds" do
          assert Calc.add(2, 3) == 5
        end
      end
      """
    )

    root
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

  defp silent_elixir_shim do
    # Reads RUN, then sleeps. Used to drive a host-side timeout
    # without the runner crashing. The shim exits cleanly when
    # stdin closes (host kills the port).
    path = Path.expand(Path.join(["tmp", "tests", "persistent", "silent_elixir.sh"]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/usr/bin/env bash
    printf 'MUT_READY\n'
    IFS= read -r _line
    sleep 60
    """)

    File.chmod!(path, 0o755)
    path
  end
end
