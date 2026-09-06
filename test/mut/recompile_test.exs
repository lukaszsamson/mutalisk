defmodule Mut.RecompileTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Bootstrap.Overlay
  alias Mut.FallbackPatch
  alias Mut.Recompile
  alias Mut.Sandbox

  test "env matches the fallback build-path contract" do
    assert Recompile.env() == [
             {"MIX_ENV", "test"},
             {"MIX_BUILD_PATH", "_build/mut_schema"},
             {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
             {"MUTALISK_ROLE", "fallback"},
             {"MUTALISK_PATH", Path.expand(File.cwd!())}
           ]
  end

  test "eval bootstraps Mix so compile-time Mix.Project code (credo-class) does not false-invalid" do
    ["--eval", eval] =
      Recompile.elixir_args("/tmp/sandbox", ["lib/foo.ex"], "demo_app")
      |> Enum.take(-2)

    assert eval =~ "Mix.start()"
    # Mix.start must precede the compile so Mix.ProjectStack is alive during it.
    assert :binary.match(eval, "Mix.start()") < :binary.match(eval, "ParallelCompiler.compile")
  end

  # A2: the child must reproduce the project's COMPILE-TIME context, not just
  # start Mix — otherwise `Application.compile_env/3` silently takes its
  # default and `Mix.Project.config()[:app]` is nil on unmodified source.
  test "eval loads the project and its config before compiling" do
    ["--eval", eval] =
      Recompile.elixir_args("/tmp/sandbox", ["lib/foo.ex"], "demo_app") |> Enum.take(-2)

    assert eval =~ "Mix.env(:test)"
    assert eval =~ ~s|Code.require_file("mix.exs", project_dir)|
    assert eval =~ ~s|Mix.Task.run("loadconfig")|
    assert eval =~ ~s(project_dir = "/tmp/sandbox")
    assert eval =~ "Code.put_compiler_option(key, value)"
    assert eval =~ "warnings_as_errors?"

    # Everything must happen before the compile pass.
    for fragment <- ["Mix.env(:test)", "loadconfig", "Code.put_compiler_option"] do
      assert :binary.match(eval, fragment) < :binary.match(eval, "ParallelCompiler.compile"),
             "#{fragment} must precede the compile"
    end

    # The lock check stays skipped: no deps loading whatsoever.
    refute eval =~ "deps.loadpaths"
    refute eval =~ "deps.check"
  end

  test "eval pushes the umbrella child's project when the mutated file is under an app" do
    root = Path.join(System.tmp_dir!(), "mut_a2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "apps", "web-ui"]))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Up.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0"]
    end
    """)

    File.write!(Path.join([root, "apps", "web-ui", "mix.exs"]), """
    defmodule WebUi.MixProject do
      use Mix.Project
      def project, do: [app: :web_ui, version: "0.1.0"]
    end
    """)

    ["--eval", eval] =
      root
      |> Recompile.elixir_args(["apps/web-ui/lib/web_ui.ex"], "web_ui")
      |> Enum.take(-2)

    assert eval =~ ~s(project_dir = "#{Path.join([root, "apps", "web-ui"])}")

    # A file outside any child falls back to the umbrella root.
    ["--eval", root_eval] =
      root |> Recompile.elixir_args(["lib/shared.ex"], "web_ui") |> Enum.take(-2)

    assert root_eval =~ ~s(project_dir = "#{root}")
  end

  # B4: the ebin target must be `_build/<env>/lib/<OTP app>/ebin`, not
  # `.../lib/<child directory>/ebin` — mutated beams written to the latter are
  # off the code path (the unmutated baseline then "survives") and the sandbox
  # reset never sweeps them.
  test "eval routes umbrella beams to the OTP app's ebin, not the child directory" do
    root = Path.join(System.tmp_dir!(), "mut_b4_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "apps", "web-ui"]))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Up.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0"]
    end
    """)

    File.write!(Path.join([root, "apps", "web-ui", "mix.exs"]), """
    defmodule WebUi.MixProject do
      use Mix.Project
      def project, do: [app: :web_ui, version: "0.1.0"]
    end
    """)

    ["--eval", eval] =
      root
      |> Recompile.elixir_args(["apps/web-ui/lib/web_ui.ex"], "web_ui")
      |> Enum.take(-2)

    assert eval =~ ~s(app_map = %{"web-ui" => "web_ui"})

    # Evaluate the generated `ebin_of` the way the child BEAM would.
    ebin_of = extract_ebin_of(eval)

    assert ebin_of.("apps/web-ui/lib/web_ui.ex") == "_build/mut_schema/lib/web_ui/ebin"

    assert ebin_of.(Path.join(root, "apps/web-ui/lib/web_ui.ex")) ==
             "_build/mut_schema/lib/web_ui/ebin"

    # Unknown child / non-umbrella path falls back to the default app.
    assert ebin_of.("lib/other.ex") == "_build/mut_schema/lib/web_ui/ebin"
  end

  test "eval keeps the single-app ebin target on the default app" do
    ["--eval", eval] =
      Recompile.elixir_args("/tmp/sandbox", ["lib/foo.ex"], "demo_app") |> Enum.take(-2)

    ebin_of = extract_ebin_of(eval)

    assert ebin_of.("lib/foo.ex") == "_build/mut_schema/lib/demo_app/ebin"
    assert ebin_of.("apps/anything/lib/foo.ex") == "_build/mut_schema/lib/demo_app/ebin"
  end

  # Runs just the `app_map = ...` and `ebin_of = ...` prelude of the generated
  # eval (everything up to the project-bootstrap section) and returns the
  # closure.
  defp extract_ebin_of(eval) do
    [prelude, _rest] = String.split(eval, Recompile.bootstrap_marker(), parts: 2)

    {ebin_of, _binding} = Code.eval_string(prelude <> "\nebin_of")

    ebin_of
  end

  @tag :integration
  test "M58: compile-time Mix.Project access recompiles WITH the eval's Mix bootstrap" do
    # Mirrors the credo `use Credo.Check` -> `Mix.ProjectStack` crash class:
    # a module reaching `Mix.Project` at COMPILE time fails in a bare
    # `elixir --eval` BEAM unless Mix is started. Proves `Mix.start()` (in the
    # recompile eval) is what makes such projects recompile instead of
    # false-invalid.
    dir = Path.join(System.tmp_dir!(), "mut_m58_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "ebin"))

    File.write!(Path.join(dir, "uses_mix.ex"), """
    defmodule UsesMix do
      @cfg Mix.Project.config()
      def cfg, do: @cfg
    end
    """)

    # Match `{:ok, _, _}` so a failed compile (ParallelCompiler returns
    # `{:error, ...}`) becomes a non-zero exit.
    compile = ~s|{:ok, _, _} = Kernel.ParallelCompiler.compile_to_path(["uses_mix.ex"], "ebin")|

    on_exit(fn -> File.rm_rf!(dir) end)

    # With Mix.start (as the recompile eval does) -> compiles cleanly.
    assert {:exit, 0, _} =
             Mut.ChildProcess.run("elixir", ["--eval", "Mix.start(); #{compile}"], cd: dir)

    # Without it -> the compile-time Mix.Project access fails (negative control).
    assert {:exit, code, _out} = Mut.ChildProcess.run("elixir", ["--eval", compile], cd: dir)
    assert code != 0
  end

  test "recompile patches one fixture file in a real sandbox and reset restores it" do
    {:ok, schema_result} = schema_result()

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "m10-recompile-sandbox", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)
    original = File.read!(Path.join(sandbox.path, "lib/guards.ex"))
    mutant = Mut.FallbackFixture.plan().fallback |> Enum.find(&(&1.mutation_kind == :boundary))
    {:ok, patch} = FallbackPatch.render(mutant, original)
    beam = Path.join(sandbox.path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Guards.beam")
    before_mtime = File.stat!(beam).mtime

    :timer.sleep(1100)
    assert :ok = FallbackPatch.apply(patch, sandbox.path)
    assert :ok = Recompile.recompile(sandbox, [patch.file], [], app: "demo_app")

    assert File.stat!(beam).mtime > before_mtime
    assert File.read!(Path.join(sandbox.path, "lib/guards.ex")) =~ "x >= 0"

    assert :ok = Sandbox.reset(sandbox)
    assert File.read!(Path.join(sandbox.path, "lib/guards.ex")) == original

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
    File.rm_rf!(schema_result.work_copy_root)
  end

  test "categorize/1 recognizes module-not-loaded as :dep_path_error" do
    samples = [
      "** (CompileError) error: module Decimal.Macros is not loaded and could not be found",
      "** (UndefinedFunctionError) function Foo.bar/2 is undefined (module Foo is not available)",
      "function Foo.bar/2 is undefined or private"
    ]

    for s <- samples do
      assert Recompile.categorize(s) == :dep_path_error, "expected :dep_path_error for: #{s}"
    end
  end

  test "categorize/1 recognizes compile errors (semantic)" do
    samples = [
      "mut.recompile errors: [{\"lib/x.ex\", 1, \"unexpected token\"}]",
      "** (CompileError) lib/x.ex: cannot compile module X"
    ]

    for s <- samples do
      assert Recompile.categorize(s) == :compile_error, "expected :compile_error for: #{s}"
    end
  end

  test "categorize/1 recognizes parse-class errors" do
    samples = [
      "** (SyntaxError) lib/x.ex:5: syntax error before: end",
      "** (TokenMissingError) lib/x.ex:5: missing terminator",
      "** (MismatchedDelimiterError) lib/x.ex:5: mismatched closing delimiter"
    ]

    for s <- samples do
      assert Recompile.categorize(s) == :parse_error, "expected :parse_error for: #{s}"
    end
  end

  test "categorize/1 falls back to :unknown for unmatched output" do
    assert Recompile.categorize("") == :unknown

    assert Recompile.categorize("** (Mix) Can't continue due to errors on dependencies") ==
             :unknown

    assert Recompile.categorize("random noise without markers") == :unknown
  end

  test "recompile returns :parse_error category for syntactically broken patch" do
    # `def add(a, b), do: a +\nend` is a parse-level failure (TokenMissingError
    # on the trailing `+`), not a CompileError. Recompile categorizes
    # parse-class output under :parse_error so reports can distinguish it
    # from semantic CompileError.
    {:ok, schema_result} = schema_result_for("compile-error")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "m17-recompile-broken", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    file_path = Path.join(sandbox.path, "lib/arith.ex")
    File.write!(file_path, "defmodule Arith do def add(a, b), do: a +\nend\n")

    assert {:error, {:recompile_failed, category, _code, _output}} =
             Recompile.recompile(sandbox, ["lib/arith.ex"], [], app: "demo_app")

    assert category == :parse_error

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
    File.rm_rf!(schema_result.work_copy_root)
  end

  test "recompile returns :dep_path_error when sibling module dep is missing" do
    {:ok, schema_result} = schema_result_for("dep-error")

    {:ok, pool} =
      Sandbox.create_pool(schema_result, 1, run_id: "m17-recompile-dep", force: true)

    {:ok, sandbox, pool} = Sandbox.checkout(pool)

    # Patch Arith to import a module that does NOT exist anywhere on
    # the sandbox's code path. The compile reaches the import and
    # fails with a "module ... is not loaded" diagnostic.
    file_path = Path.join(sandbox.path, "lib/arith.ex")

    File.write!(file_path, """
    defmodule Arith do
      import Bogus.Missing.Module
      def add(a, b), do: a + b
    end
    """)

    assert {:error, {:recompile_failed, category, _code, _output}} =
             Recompile.recompile(sandbox, ["lib/arith.ex"], [], app: "demo_app")

    assert category == :dep_path_error

    sandbox |> Sandbox.checkin(pool) |> Sandbox.destroy_pool()
    File.rm_rf!(schema_result.work_copy_root)
  end

  # A2 regression: before the project bootstrap, this recompile of UNMODIFIED
  # source returned `{:default, nil}` — the compile-time environment differed
  # from the real build, so a mutation elsewhere in the file could flip
  # unrelated behaviour (false kills/survivors).
  test "recompile reproduces compile_env and Mix.Project.config from the project" do
    dir =
      work_copy("mut_compile_env", """
      defmodule Probe.MixProject do
        use Mix.Project
        def project, do: [app: :mut_compile_env_probe, version: "0.1.0"]
      end
      """)

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config

    config :mut_compile_env_probe, :label, :configured
    """)

    File.write!(Path.join(dir, "lib/probe.ex"), """
    defmodule Probe do
      @label Application.compile_env(:mut_compile_env_probe, :label, :default)
      @app Mix.Project.config()[:app]
      def value, do: {@label, @app}
    end
    """)

    assert :ok =
             Recompile.recompile(%Sandbox{path: dir}, ["lib/probe.ex"], [],
               app: "mut_compile_env_probe"
             )

    assert eval_in_ebin(dir, "mut_compile_env_probe", "Probe.value()") ==
             "{:configured, :mut_compile_env_probe}"
  end

  # `:warnings_as_errors` lives in `:elixirc_options` and is enforced by Mix
  # (not by the compiler), so the child has to apply it itself; otherwise a
  # mutant that only introduces a warning compiles here while the project's
  # real build rejects it.
  test "recompile honors elixirc_options: [warnings_as_errors: true]" do
    warning_source = """
    defmodule Warns do
      def f(unused_on_purpose), do: :ok
    end
    """

    strict =
      work_copy("mut_waer_strict", """
      defmodule Strict.MixProject do
        use Mix.Project

        def project do
          [app: :mut_waer_strict, version: "0.1.0", elixirc_options: [warnings_as_errors: true]]
        end
      end
      """)

    File.write!(Path.join(strict, "lib/warns.ex"), warning_source)

    assert {:error, {:recompile_failed, :compile_error, code, output}} =
             Recompile.recompile(%Sandbox{path: strict}, ["lib/warns.ex"], [],
               app: "mut_waer_strict"
             )

    assert code != 0
    assert output =~ "warnings-as-errors"

    # Control: the identical warning compiles when the project does not opt in.
    lax =
      work_copy("mut_waer_lax", """
      defmodule Lax.MixProject do
        use Mix.Project
        def project, do: [app: :mut_waer_lax, version: "0.1.0"]
      end
      """)

    File.write!(Path.join(lax, "lib/warns.ex"), warning_source)

    assert :ok =
             Recompile.recompile(%Sandbox{path: lax}, ["lib/warns.ex"], [], app: "mut_waer_lax")
  end

  test "recompile still succeeds when the work copy has no mix.exs to load" do
    dir = Path.join(System.tmp_dir!(), "mut_nomix_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "_build/mut_schema/lib/mut_nomix/ebin"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "lib/plain.ex"), "defmodule Plain do\n  def f, do: 1\nend\n")

    assert :ok = Recompile.recompile(%Sandbox{path: dir}, ["lib/plain.ex"], [], app: "mut_nomix")
    assert eval_in_ebin(dir, "mut_nomix", "Plain.f()") == "1"
  end

  # A minimal schema-shaped work copy: the user's `mix.exs` renamed to
  # `mix_user.exs` and wrapped by the generated overlay, exactly as
  # `Mut.Bootstrap.Overlay.materialize/2` leaves it, plus the `_build/mut_schema`
  # ebin the recompile writes into. Deliberately avoids a full oracle/schema
  # build: the child bootstrap is what is under test here.
  defp work_copy(name, user_mix_exs) do
    dir = Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "config"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "mix_user.exs"), user_mix_exs)
    File.write!(Path.join(dir, "mix.exs"), Overlay.render(:schema))

    dir
  end

  defp eval_in_ebin(dir, app, expression) do
    ebin = Path.join(dir, "_build/mut_schema/lib/#{app}/ebin")

    {output, 0} =
      System.cmd("elixir", ["-pa", ebin, "-e", "IO.write(inspect(#{expression}))"],
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  defp schema_result do
    schema_result_for("default")
  end

  defp schema_result_for(suffix) do
    fixture_root = Path.expand("test/fixtures/demo_app")

    {:ok, oracle} =
      Mut.OracleBuild.run(fixture_root, run_id: "recompile-oracle-#{suffix}", force: true)

    plan = Mut.Orchestrator.plan(fixture_root, oracle)

    Mut.SchemaBuild.build(plan,
      user_project_root: fixture_root,
      run_id: "recompile-schema-#{suffix}",
      force: true,
      keep: true
    )
  end
end
