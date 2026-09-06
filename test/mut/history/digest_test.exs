defmodule Mut.History.DigestTest do
  use ExUnit.Case, async: true

  alias Mut.History.Digest

  @v1 """
  defmodule Sample do
    def alpha(x), do: x + 1

    def beta(x) do
      y = x * 2
      y - 3
    end

    @answer 42
  end
  """

  # Only beta's body changes (`* 2` -> `* 4`); alpha + the attribute unchanged.
  @v2 """
  defmodule Sample do
    def alpha(x), do: x + 1

    def beta(x) do
      y = x * 4
      y - 3
    end

    @answer 42
  end
  """

  defp lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
  end

  defp line_of(source, needle) do
    {_text, n} = Enum.find(lines(source), fn {text, _n} -> String.contains?(text, needle) end)
    n
  end

  describe "source_digest — function-level isolation" do
    test "editing one function changes only that function's mutants' digest" do
      i1 = Digest.function_index(@v1)
      i2 = Digest.function_index(@v2)

      alpha_line = line_of(@v1, "def alpha")
      beta_line = line_of(@v1, "y = x")

      assert Digest.source_digest(i1, alpha_line) == Digest.source_digest(i2, alpha_line)
      refute Digest.source_digest(i1, beta_line) == Digest.source_digest(i2, beta_line)
    end

    test "non-function-scoped line falls back to a stable whole-file digest" do
      i1 = Digest.function_index(@v1)
      attr_line = line_of(@v1, "@answer")
      # The attribute line is in no def -> file digest. Same on a re-index.
      assert Digest.source_digest(i1, attr_line) ==
               Digest.source_digest(Digest.function_index(@v1), attr_line)
    end

    test "whitespace-only churn does not change a function digest" do
      reindented = String.replace(@v1, "    y = x * 2", "        y = x * 2")
      beta_line = line_of(@v1, "y = x")

      assert Digest.source_digest(Digest.function_index(@v1), beta_line) ==
               Digest.source_digest(Digest.function_index(reindented), beta_line)
    end

    test "unparseable source degrades to a file-only index (no crash)" do
      index = Digest.function_index("defmodule Broken do def foo(")
      assert is_binary(Digest.source_digest(index, 1))
    end
  end

  describe "selected_tests_digest" do
    test "order-insensitive, content-sensitive" do
      a = [{"test/a_test.exs", "assert foo() == 1"}, {"test/b_test.exs", "assert bar() == 2"}]
      reordered = Enum.reverse(a)

      changed = [
        {"test/a_test.exs", "assert foo() == 99"},
        {"test/b_test.exs", "assert bar() == 2"}
      ]

      assert Digest.selected_tests_digest(a) == Digest.selected_tests_digest(reordered)
      refute Digest.selected_tests_digest(a) == Digest.selected_tests_digest(changed)
    end

    test "empty selection is a stable digest" do
      assert Digest.selected_tests_digest([]) == Digest.selected_tests_digest([])
    end
  end

  describe "content_digest" do
    test "pure-formatting churn does not change the digest" do
      a = "defmodule A do\n  def f, do: 1\nend\n"
      b = "defmodule A do\n\n  # a comment\n      def    f,   do:   1\nend"
      assert Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "semantic code change changes the digest" do
      a = "def f, do: 1"
      b = "def f, do: 2"
      refute Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "editing inside a string literal changes the digest (R4)" do
      a = ~s|def f, do: "a  b"|
      b = ~s|def f, do: "a b"|
      refute Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "non-Elixir / binary content falls back to raw bytes" do
      assert Digest.content_digest(<<0, 1, 2>>) == Digest.content_digest(<<0, 1, 2>>)
      refute Digest.content_digest(<<0, 1, 2>>) == Digest.content_digest(<<0, 1, 3>>)
    end

    test "invalid UTF-8 (e.g. a gzip/binary priv asset) does not crash" do
      # `Code.string_to_quoted` runs `String.to_charlist`, which RAISES on
      # invalid UTF-8 — caught a real `project_digest` crash on a binary priv
      # file. <<0,1,2>> is valid UTF-8; a gzip header (0x1f 0x8b ...) is not.
      gz = <<0x1F, 0x8B, 0x08, 0x00, 0xC5, 0x49, 0x25, 0xE5>>
      assert is_binary(Digest.content_digest(gz))
      refute Digest.content_digest(gz) == Digest.content_digest(gz <> <<0xFF>>)
    end
  end

  describe "project_digest" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_proj_digest_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "test/support"))
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
      File.write!(Path.join(root, "test/support/helper.ex"), "defmodule H do\nend\n")
      File.write!(Path.join(root, "test/a_test.exs"), "assert A.f() == 1")
      File.write!(Path.join(root, "config/test.exs"), "import Config\n")
      File.write!(Path.join(root, "mix.lock"), "%{}\n")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "stable when nothing changes", %{root: root} do
      assert Digest.project_digest(root) == Digest.project_digest(root)
    end

    test "changes when a non-mutant lib file changes (cross-file dependency)", %{root: root} do
      before = Digest.project_digest(root)
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 2\nend\n")
      refute Digest.project_digest(root) == before
    end

    test "changes when test support / config / mix.lock change", %{root: root} do
      for rel <- ["test/support/helper.ex", "config/test.exs", "mix.lock"] do
        before = Digest.project_digest(root)
        File.write!(Path.join(root, rel), "# changed #{rel}\n")
        refute Digest.project_digest(root) == before, "expected #{rel} to change the fingerprint"
      end
    end

    test "ignores _test.exs files (handled per-mutant by selected_tests_digest)", %{root: root} do
      before = Digest.project_digest(root)
      File.write!(Path.join(root, "test/a_test.exs"), "assert A.f() == 999")
      assert Digest.project_digest(root) == before
    end

    test "fingerprints umbrella child-app source under apps/* (R4)", %{root: root} do
      app_lib = Path.join(root, "apps/a/lib")
      File.mkdir_p!(app_lib)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 1\nend\n")

      before = Digest.project_digest(root)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 2\nend\n")

      refute Digest.project_digest(root) == before,
             "editing apps/a/lib/helper.ex must change the fingerprint"
    end

    test "fingerprints priv assets under a dot-directory (R4 dotfile gap)", %{root: root} do
      seed = Path.join(root, "priv/.migrations/seed.exs")
      File.mkdir_p!(Path.dirname(seed))
      File.write!(seed, "[count: 1]\n")

      before = Digest.project_digest(root)
      File.write!(seed, "[count: 2]\n")

      refute Digest.project_digest(root) == before,
             "editing priv/.migrations/seed.exs must change the fingerprint"
    end

    test "a non-source priv asset is hashed byte-exact, not AST-normalized (R4)", %{root: root} do
      # `1.50` and `1.5` parse to the SAME Elixir AST, so AST-normalizing this
      # asset would collapse a behaviour-affecting change (a test asserting the
      # served string "1.50") and reuse a stale verdict. A data file must be
      # byte-exact.
      rates = Path.join(root, "priv/rates.txt")
      File.mkdir_p!(Path.dirname(rates))
      File.write!(rates, "1.50\n")

      before = Digest.project_digest(root)
      File.write!(rates, "1.5\n")

      refute Digest.project_digest(root) == before,
             "a byte-level change to a priv data file must change the fingerprint"
    end

    test "fingerprints the overlay-renamed user mix.exs (mix_user.exs)", %{root: root} do
      # In an overlayed work copy the user's real mix.exs is renamed to
      # mix_user.exs; a dep/config change there must invalidate reuse even when
      # mix.lock is untouched.
      user_mix = Path.join(root, "mix_user.exs")
      File.write!(user_mix, "defmodule M.MixProject do\n  def project, do: [app: :m]\nend\n")

      before = Digest.project_digest(root)

      File.write!(
        user_mix,
        "defmodule M.MixProject do\n  def project, do: [app: :m, elixirc_paths: [\"x\"]]\nend\n"
      )

      refute Digest.project_digest(root) == before,
             "editing mix_user.exs must change the fingerprint"
    end

    test "fingerprints a non-Elixir test fixture read by a test", %{root: root} do
      fixture = Path.join(root, "test/fixtures/data.json")
      File.mkdir_p!(Path.dirname(fixture))
      File.write!(fixture, ~s({"v": 1}\n))

      before = Digest.project_digest(root)
      File.write!(fixture, ~s({"v": 2}\n))

      refute Digest.project_digest(root) == before,
             "editing a test fixture must change the fingerprint"
    end

    test "a standard apps/ umbrella (default apps_path) still fingerprints child-app source (T18)",
         %{root: root} do
      # `Digest.project_digest` must not regress for the common case: an
      # umbrella with no `:apps_path` override (or an explicit `apps_path:
      # "apps"`) resolves to the same "apps" globs as before this change.
      File.write!(
        Path.join(root, "mix.exs"),
        "defmodule Root.MixProject do\n  def project, do: [apps_path: \"apps\"]\nend\n"
      )

      app_lib = Path.join(root, "apps/a/lib")
      File.mkdir_p!(app_lib)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 1\nend\n")

      before = Digest.project_digest(root)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 2\nend\n")

      refute Digest.project_digest(root) == before,
             "editing apps/a/lib/helper.ex under a default-valued apps_path must change the fingerprint"
    end

    test "a non-umbrella project's digest is unaffected by apps_path resolution (T18)", %{
      root: root
    } do
      # No mix.exs declaring :apps_path at all (the common single-app case) —
      # `Mut.Umbrella.apps_path_name/1` must default to "apps" without raising,
      # and the digest must depend only on the files that actually exist.
      before = Digest.project_digest(root)
      assert Digest.project_digest(root) == before
    end

    test "editing a file under a custom apps_path (mix.exs apps_path: \"packages\") changes the digest (T18)",
         %{root: root} do
      File.write!(
        Path.join(root, "mix.exs"),
        "defmodule Root.MixProject do\n  def project, do: [apps_path: \"packages\"]\nend\n"
      )

      app_lib = Path.join(root, "packages/foo/lib")
      File.mkdir_p!(app_lib)

      File.write!(
        Path.join(app_lib, "helper.ex"),
        "defmodule Foo.Helper do\n  def g, do: 1\nend\n"
      )

      before = Digest.project_digest(root)

      File.write!(
        Path.join(app_lib, "helper.ex"),
        "defmodule Foo.Helper do\n  def g, do: 2\nend\n"
      )

      refute Digest.project_digest(root) == before,
             "editing packages/foo/lib/helper.ex (custom apps_path) must change the fingerprint"
    end
  end

  describe "input_digest (T19: .eex/.heex are hashed byte-exact, not AST-normalized)" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_proj_digest_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "editing a .heex template's content changes the project digest", %{root: root} do
      template = Path.join(root, "lib/page.html.heex")
      # Both bodies parse as Elixir and AST-normalise to the same string, so
      # the old parse-then-Macro.to_string path collapsed them.
      File.write!(template, "Hello  world\n")

      before = Digest.project_digest(root)
      File.write!(template, "Hello world\n")

      refute Digest.project_digest(root) == before,
             "a behaviour-affecting .heex byte edit must change the fingerprint even though it AST-normalizes to the same Elixir literal"
    end
  end

  # F6: `mix.exs`/`mix.lock` cannot identify the CONTENTS of a `path:`
  # dependency, and the fixed `lib/**` globs miss custom `:elixirc_paths`
  # source roots. Editing either used to leave every digest unchanged, so
  # `Mut.History.Reuse.decide/4` handed back a stale `:killed` verdict.
  describe "project_digest — path dependencies and extra source roots (F6)" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_path_dep_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def f, do: LocalDep.value(1)\nend\n"
      )

      File.write!(Path.join(root, "mix.lock"), "%{}\n")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp write_dep!(root, name, body) do
      dep = Path.join(root, name)
      File.mkdir_p!(Path.join(dep, "lib"))
      File.write!(Path.join([dep, "lib", "#{name}.ex"]), body)

      File.write!(Path.join(dep, "mix.exs"), """
      defmodule Dep.MixProject do
        use Mix.Project
        def project, do: [app: :#{name}, version: "0.1.0"]
      end
      """)

      dep
    end

    defp write_mix!(root, deps_body, extra \\ "") do
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Sample.MixProject do
        use Mix.Project

        def project do
          [app: :sample, version: "0.1.0"#{extra}, deps: deps()]
        end

        defp deps do
          #{deps_body}
        end
      end
      """)
    end

    test "editing a path dependency's lib changes the digest", %{root: root} do
      dep = write_dep!(root, "local_dep", "defmodule LocalDep do\n  def value(x), do: x\nend\n")
      write_mix!(root, ~s([{:local_dep, path: "local_dep"}]))

      before = Digest.project_digest(root)

      File.write!(
        Path.join(dep, "lib/local_dep.ex"),
        "defmodule LocalDep do\n  def value(_x), do: 0\nend\n"
      )

      refute Digest.project_digest(root) == before,
             "editing local_dep/lib/local_dep.ex must invalidate reuse"
    end

    test "editing a path dependency's priv/config/mix.exs changes the digest", %{root: root} do
      dep = write_dep!(root, "local_dep", "defmodule LocalDep do\n  def value(x), do: x\nend\n")
      write_mix!(root, ~s([{:local_dep, path: "local_dep"}]))
      File.mkdir_p!(Path.join(dep, "priv"))
      File.mkdir_p!(Path.join(dep, "config"))
      File.write!(Path.join(dep, "priv/rates.txt"), "1.50\n")
      File.write!(Path.join(dep, "config/config.exs"), "import Config\n")

      for {rel, changed} <- [
            {"priv/rates.txt", "1.5\n"},
            {"config/config.exs", "import Config\nconfig :local_dep, x: 1\n"},
            {"mix.exs", "# touched\n"}
          ] do
        before = Digest.project_digest(root)
        File.write!(Path.join(dep, rel), changed)

        refute Digest.project_digest(root) == before,
               "expected local_dep/#{rel} to change the fingerprint"
      end
    end

    test "a path dependency's _build and deps are pruned", %{root: root} do
      dep = write_dep!(root, "local_dep", "defmodule LocalDep do\n  def value(x), do: x\nend\n")
      write_mix!(root, ~s([{:local_dep, path: "local_dep"}]))
      File.mkdir_p!(Path.join(dep, "lib/_build"))
      File.mkdir_p!(Path.join(dep, "priv/deps"))

      before = Digest.project_digest(root)
      File.write!(Path.join(dep, "lib/_build/artifact.ex"), "# build state\n")
      File.write!(Path.join(dep, "priv/deps/vendored.txt"), "vendored\n")

      assert Digest.project_digest(root) == before,
             "build state and vendored deps inside a path dep are not project inputs"
    end

    test "a 3-tuple dep and an @attribute path are both resolved", %{root: root} do
      dep = write_dep!(root, "local_dep", "defmodule LocalDep do\n  def value(x), do: x\nend\n")

      for deps_body <- [
            ~s([{:local_dep, ">= 0.0.0", path: "local_dep"}]),
            ~s([{:local_dep, path: @dep_path}])
          ] do
        write_mix!(root, deps_body)

        File.write!(
          Path.join(root, "mix.exs"),
          String.replace(
            File.read!(Path.join(root, "mix.exs")),
            "use Mix.Project",
            ~s(use Mix.Project\n  @dep_path "local_dep")
          )
        )

        assert {:ok, before} = Digest.project_fingerprint(root)

        File.write!(
          Path.join(dep, "lib/local_dep.ex"),
          "defmodule LocalDep do\n  def value(_x), do: #{:erlang.unique_integer([:positive])}\nend\n"
        )

        assert {:ok, after_edit} = Digest.project_fingerprint(root)
        refute after_edit == before, "expected #{deps_body} to be resolved and fingerprinted"
      end
    end

    test "an extra elixirc_paths source root is fingerprinted (literal list form)", %{root: root} do
      File.mkdir_p!(Path.join(root, "src"))
      File.write!(Path.join(root, "src/other.ex"), "defmodule Other do\n  def g, do: 1\nend\n")
      write_mix!(root, "[]", ~s(, elixirc_paths: ["lib", "src"]))

      before = Digest.project_digest(root)
      File.write!(Path.join(root, "src/other.ex"), "defmodule Other do\n  def g, do: 2\nend\n")

      refute Digest.project_digest(root) == before,
             "editing an elixirc_paths source root must change the fingerprint"
    end

    test "the elixirc_paths(Mix.env()) function form unions every clause's roots", %{root: root} do
      for dir <- ["src", "gen"], do: File.mkdir_p!(Path.join(root, dir))
      File.write!(Path.join(root, "src/other.ex"), "defmodule Other do\n  def g, do: 1\nend\n")
      File.write!(Path.join(root, "gen/made.ex"), "defmodule Made do\n  def g, do: 1\nend\n")

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Sample.MixProject do
        use Mix.Project

        def project do
          [app: :sample, version: "0.1.0", elixirc_paths: elixirc_paths(Mix.env())]
        end

        defp elixirc_paths(:test), do: ["lib", "src", "gen"]
        defp elixirc_paths(_env), do: ["lib", "src"]
      end
      """)

      for rel <- ["src/other.ex", "gen/made.ex"] do
        before = Digest.project_digest(root)
        File.write!(Path.join(root, rel), "# changed #{rel}\n")

        refute Digest.project_digest(root) == before,
               "expected #{rel} (a literal root in some elixirc_paths clause) to be fingerprinted"
      end
    end

    test "umbrella child path deps are fingerprinted per app", %{root: root} do
      child = Path.join(root, "apps/web")
      File.mkdir_p!(Path.join(child, "lib"))

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Umbrella.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0"]
      end
      """)

      dep = write_dep!(child, "child_dep", "defmodule ChildDep do\n  def v, do: 1\nend\n")

      File.write!(Path.join(child, "mix.exs"), """
      defmodule Web.MixProject do
        use Mix.Project
        def project, do: [app: :web, version: "0.1.0", deps: deps()]
        defp deps, do: [{:child_dep, path: "child_dep"}]
      end
      """)

      before = Digest.project_digest(root)

      File.write!(
        Path.join(dep, "lib/child_dep.ex"),
        "defmodule ChildDep do\n  def v, do: 2\nend\n"
      )

      refute Digest.project_digest(root) == before,
             "editing apps/web/child_dep/lib/child_dep.ex must change the fingerprint"
    end
  end

  describe "project_fingerprint — the reuse gate (F6)" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_fingerprint_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp write_deps_mix!(root, deps_body) do
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Sample.MixProject do
        use Mix.Project
        def project, do: [app: :sample, version: "0.1.0", deps: deps()]
        defp deps, do: #{deps_body}
      end
      """)
    end

    test "a fully resolvable project yields {:ok, project_digest/1}", %{root: root} do
      write_deps_mix!(root, ~s([{:jason, "~> 1.4"}]))
      assert {:ok, digest} = Digest.project_fingerprint(root)
      assert digest == Digest.project_digest(root)
    end

    test "a project with no mix.exs at all yields {:ok, _}", %{root: root} do
      assert {:ok, _digest} = Digest.project_fingerprint(root)
    end

    test "path: keys outside the deps declaration (escript, releases) are not path deps",
         %{root: root} do
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Sample.MixProject do
        use Mix.Project

        def project do
          [
            app: :sample,
            version: "0.1.0",
            escript: [main_module: Sample.CLI, path: "bin/sample"],
            releases: [sample: [path: "rel/sample"]],
            deps: deps()
          ]
        end

        defp deps, do: [{:jason, "~> 1.4"}]
      end
      """)

      assert {:ok, _digest} = Digest.project_fingerprint(root)
    end

    test "a sibling path: dep outside the (copied) project resolves via :user_root", %{root: root} do
      # Unique sibling name: `root` lives in the shared tmp dir, so a fixed
      # `../shared` could collide with another test's leftovers.
      sibling = "mut_shared_#{System.unique_integer([:positive])}"
      # `root` stands in for the work copy: the sibling does not exist next to it.
      write_deps_mix!(root, ~s|[{:shared, path: "../#{sibling}"}]|)
      assert {:disable, [reason]} = Digest.project_fingerprint(root)
      assert reason =~ "points at missing ../#{sibling}"

      base = Path.join(System.tmp_dir!(), "mut_user_base_#{System.unique_integer([:positive])}")
      user_root = Path.join(base, "project")
      shared = Path.join(base, sibling)
      File.mkdir_p!(Path.join(shared, "lib"))
      File.mkdir_p!(user_root)
      on_exit(fn -> File.rm_rf!(base) end)
      File.write!(Path.join(shared, "lib/shared.ex"), "defmodule Shared, do: def v, do: 1\n")

      assert {:ok, before} = Digest.project_fingerprint(root, user_root: user_root)
      File.write!(Path.join(shared, "lib/shared.ex"), "defmodule Shared, do: def v, do: 2\n")
      assert {:ok, after_edit} = Digest.project_fingerprint(root, user_root: user_root)
      assert before != after_edit
    end

    test "a non-literal path: expression disables reuse", %{root: root} do
      write_deps_mix!(root, ~s|[{:local_dep, path: System.get_env("DEP")}]|)

      assert {:disable, [reason]} = Digest.project_fingerprint(root)
      assert reason =~ "path dependency :local_dep"
      assert reason =~ "mix.exs"
      assert reason =~ "non-literal"
    end

    test "a path: pointing at a missing directory disables reuse", %{root: root} do
      write_deps_mix!(root, ~s([{:local_dep, path: "nowhere"}]))

      assert {:disable, [reason]} = Digest.project_fingerprint(root)
      assert reason =~ "points at missing nowhere"
    end

    test "an unparseable mix.exs disables reuse", %{root: root} do
      File.write!(Path.join(root, "mix.exs"), "defmodule Broken do\n  def project, do: [\n")

      assert {:disable, [reason]} = Digest.project_fingerprint(root)
      assert reason =~ "could not be parsed"
    end

    test "an unresolvable path dep in an umbrella CHILD disables reuse", %{root: root} do
      child = Path.join(root, "apps/web")
      File.mkdir_p!(Path.join(child, "lib"))

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Umbrella.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0"]
      end
      """)

      write_deps_mix!(child, ~s|[{:child_dep, path: Path.expand("../child_dep", __DIR__)}]|)

      assert {:disable, [reason]} = Digest.project_fingerprint(root)
      assert reason =~ "path dependency :child_dep"
      assert reason =~ Path.join("apps", "web")
    end

    test "the overlay's generated mix.exs is ignored in favour of mix_user.exs", %{root: root} do
      # The work copy's `mix.exs` is Mutalisk's own overlay (it pins
      # `{:mutalisk, path: <non-literal>}`); the user's real one is renamed to
      # `mix_user.exs`. Reading the overlay would disable reuse on every run.
      File.write!(Path.join(root, "mix.exs"), """
      defmodule Overlay.MixProject do
        use Mix.Project
        def project, do: [app: :sample, deps: deps()]
        defp deps, do: [{:mutalisk, path: System.fetch_env!("MUTALISK_PATH")}]
      end
      """)

      File.write!(Path.join(root, "mix_user.exs"), """
      defmodule Sample.MixProject do
        use Mix.Project
        def project, do: [app: :sample, version: "0.1.0"]
      end
      """)

      assert {:ok, _digest} = Digest.project_fingerprint(root)
    end
  end

  # The F6 fingerprint must NOT perturb the digest of an ordinary project (no
  # path deps, no custom source roots): a changed digest would cold-start every
  # existing warm history on upgrade. This value was captured by running
  # `Digest.project_digest/1` on exactly this fixture at the base commit
  # (622fc93), before the F6 change.
  describe "project_digest — byte identity with the pre-F6 fingerprint" do
    @pre_f6_digest "9a3837806f2dc8284f0546631a4a8e12"

    test "a project without path deps or extra source roots digests identically" do
      root =
        Path.join(System.tmp_dir!(), "mut_byte_identity_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)

      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "test/support"))
      File.mkdir_p!(Path.join(root, "config"))
      File.mkdir_p!(Path.join(root, "priv"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
      File.write!(Path.join(root, "test/support/helper.ex"), "defmodule H do\nend\n")
      File.write!(Path.join(root, "test/a_test.exs"), "assert A.f() == 1\n")
      File.write!(Path.join(root, "config/test.exs"), "import Config\n")
      File.write!(Path.join(root, "priv/data.txt"), "1.50\n")
      File.write!(Path.join(root, "mix.lock"), "%{}\n")

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Baseline.MixProject do
        use Mix.Project

        def project do
          [app: :baseline, version: "0.1.0", deps: deps()]
        end

        defp deps do
          [{:jason, "~> 1.4"}]
        end
      end
      """)

      assert Digest.project_digest(root) == @pre_f6_digest
      assert {:ok, @pre_f6_digest} = Digest.project_fingerprint(root)
    end
  end
end
