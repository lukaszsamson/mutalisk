defmodule Mut.RecompileTest do
  use ExUnit.Case, async: false

  @moduledoc false

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
  # eval (everything up to the compile call) and returns the closure.
  defp extract_ebin_of(eval) do
    [prelude, _rest] = String.split(eval, "case Kernel.ParallelCompiler", parts: 2)

    {ebin_of, _binding} =
      prelude
      |> String.replace("Mix.start()", "")
      |> Kernel.<>("\nebin_of")
      |> Code.eval_string()

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
