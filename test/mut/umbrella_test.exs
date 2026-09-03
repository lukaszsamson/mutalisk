defmodule Mut.UmbrellaTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Umbrella

  defp app(src), do: src |> Code.string_to_quoted!() |> Umbrella.app_from_ast()

  describe "app_from_ast/1" do
    test "literal app: :name" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               def project, do: [app: :my_app, version: "0.1.0"]
             end
             """) == "my_app"
    end

    test "@app module-attribute idiom resolves to the literal (R1)" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               @app :my_app
               def project, do: [app: @app, version: "0.1.0"]
             end
             """) == "my_app"
    end

    test "does not return the string \"nil\" for the @app idiom (R1 regression)" do
      refute app("""
             defmodule My.MixProject do
               use Mix.Project
               @app :my_app
               def project, do: [app: @app]
             end
             """) == "nil"
    end

    test "unresolvable @app yields nil, not \"nil\"" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               def project, do: [app: @app]
             end
             """) == nil
    end

    test "a re-defined @app resolves to its LAST value (last-write-wins)" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               @app :placeholder
               @app :real_app
               def project, do: [app: @app, version: "0.1.0"]
             end
             """) == "real_app"
    end

    test "T21: `app: false` in a dep listed BEFORE project/0 must not win" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project

               @deps [
                 {:plug, "~> 1.0", app: false},
                 {:other, path: "../other", app: false}
               ]

               def project, do: [app: :my_app, version: "0.1.0", deps: @deps]
             end
             """) == "my_app"
    end

    test "T21: an unrelated keyword with an :app key before project/0 does not win" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project

               def application, do: [mod: {My.App, []}]
               defp release_opts, do: [app: :wrong_name, steps: [:assemble]]

               def project, do: [app: :my_app, version: "0.1.0", releases: [r: release_opts()]]
             end
             """) == "my_app"
    end

    test "T21: @app attribute still resolves when read structurally" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               @app :my_app
               @deps [{:plug, "~> 1.0", app: false}]

               def project do
                 [app: @app, version: "0.1.0", deps: @deps]
               end
             end
             """) == "my_app"
    end

    test "T21: a missing project/0 returns nil" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               @deps [{:plug, "~> 1.0", app: false}]
               def application, do: [app: :not_the_project]
             end
             """) == nil
    end

    test "T21: project/0 returning `[app: ...] ++ shared` still resolves" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project
               def project, do: [app: :my_app] ++ shared()
               defp shared, do: [version: "0.1.0"]
             end
             """) == "my_app"
    end

    test "T21: a block body resolves from its final keyword list" do
      assert app("""
             defmodule My.MixProject do
               use Mix.Project

               def project do
                 _ = [app: :decoy]
                 [app: :my_app, version: "0.1.0"]
               end
             end
             """) == "my_app"
    end
  end

  describe "app_dirs/1 (T20)" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_app_dirs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "apps"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0"]
      end
      """)

      {:ok, root: root}
    end

    defp write_app(root, name) do
      dir = Path.join([root, "apps", name])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule #{Macro.camelize(name)}.MixProject do
        use Mix.Project
        def project, do: [app: :#{name}, version: "0.1.0"]
      end
      """)

      dir
    end

    test "ignores a stray FILE under apps/", %{root: root} do
      dir = write_app(root, "app_a")
      File.write!(Path.join([root, "apps", "README.md"]), "not an app\n")

      assert Umbrella.app_dirs(root) == [dir]
      assert Umbrella.app_names(root) == ["app_a"]
      assert Umbrella.default_test_dirs(root) == ["apps/app_a/test"]
    end

    test "ignores a stray non-Mix DIRECTORY under apps/", %{root: root} do
      dir = write_app(root, "app_a")
      File.mkdir_p!(Path.join([root, "apps", "_build_leftover", "ebin"]))

      assert Umbrella.app_dirs(root) == [dir]
      assert Umbrella.app_names(root) == ["app_a"]
    end

    test "keeps an app whose mix.exs was renamed to mix_user.exs by the overlay", %{root: root} do
      dir = write_app(root, "app_a")
      File.rename!(Path.join(dir, "mix.exs"), Path.join(dir, "mix_user.exs"))

      assert Umbrella.app_dirs(root) == [dir]
    end
  end

  describe "default_test_dirs/1" do
    @fixture_umbrella Path.expand("../fixtures/overlay_cases/umbrella", __DIR__)

    test "umbrella: each child app's apps/<app>/test (issue #3 regression)" do
      dirs = Umbrella.default_test_dirs(@fixture_umbrella)

      assert dirs == ["apps/app_a/test", "apps/app_b/test"]
    end

    test "single app: plain test/" do
      root = Path.join(System.tmp_dir!(), "mut_single_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Single.MixProject do
        use Mix.Project
        def project, do: [app: :single, version: "0.1.0"]
      end
      """)

      assert Umbrella.default_test_dirs(root) == ["test"]
    end

    test "custom :apps_path is honoured" do
      root = Path.join(System.tmp_dir!(), "mut_custom_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "packages", "thing"]))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: "packages", version: "0.1.0"]
      end
      """)

      File.write!(Path.join([root, "packages", "thing", "mix.exs"]), """
      defmodule Thing.MixProject do
        use Mix.Project
        def project, do: [app: :thing, version: "0.1.0"]
      end
      """)

      assert Umbrella.default_test_dirs(root) == ["packages/thing/test"]
    end

    test "@apps_path module attribute is honoured" do
      root = Path.join(System.tmp_dir!(), "mut_attr_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "packages", "thing"]))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        @apps_path "packages"
        def project, do: [apps_path: @apps_path, version: "0.1.0"]
      end
      """)

      File.write!(Path.join([root, "packages", "thing", "mix.exs"]), """
      defmodule Thing.MixProject do
        use Mix.Project
        def project, do: [app: :thing, version: "0.1.0"]
      end
      """)

      assert Umbrella.umbrella?(root)
      assert Umbrella.app_dirs(root) == [Path.join([root, "packages", "thing"])]
      assert Umbrella.default_test_dirs(root) == ["packages/thing/test"]
    end
  end

  describe "apps_path_name/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_apps_path_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp write_mix(root, body) do
      File.write!(Path.join(root, "mix.exs"), body)
    end

    test "returns the configured custom :apps_path", %{root: root} do
      write_mix(root, """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: "packages", version: "0.1.0"]
      end
      """)

      assert Umbrella.apps_path_name(root) == "packages"
    end

    test "returns @apps_path module attribute value", %{root: root} do
      write_mix(root, """
      defmodule Up.MixProject do
        use Mix.Project
        @apps_path "packages"
        def project, do: [apps_path: @apps_path, version: "0.1.0"]
      end
      """)

      assert Umbrella.apps_path_name(root) == "packages"
    end

    test "defaults to \"apps\" for a single-app project or unset :apps_path", %{root: root} do
      write_mix(root, """
      defmodule Single.MixProject do
        use Mix.Project
        def project, do: [app: :single, version: "0.1.0"]
      end
      """)

      assert Umbrella.apps_path_name(root) == "apps"
    end
  end

  # B4: a child app's DIRECTORY name need not equal its OTP `:app`. Source
  # paths use the directory (`apps/web-ui/lib/...`) while Mix writes build
  # artefacts under the OTP app (`_build/<env>/lib/web_ui/`). These cover the
  # mapping both directions.
  describe "app_map/1 and otp_app_for_file/2 (B4)" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_app_map_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp write_umbrella(root, apps_path, children) do
      File.mkdir_p!(root)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: #{inspect(apps_path)}, version: "0.1.0"]
      end
      """)

      Enum.each(children, fn {dir, app} ->
        child = Path.join([root, apps_path, dir])
        File.mkdir_p!(child)

        File.write!(Path.join(child, "mix.exs"), """
        defmodule #{Macro.camelize(app)}.MixProject do
          use Mix.Project
          def project, do: [app: :#{app}, version: "0.1.0"]
        end
        """)
      end)

      root
    end

    test "maps directory basenames to OTP app names", %{root: root} do
      write_umbrella(root, "apps", [{"web-ui", "web_ui"}, {"backoffice", "bo"}, {"core", "core"}])

      assert Umbrella.app_map(root) == %{
               "web-ui" => "web_ui",
               "backoffice" => "bo",
               "core" => "core"
             }
    end

    test "resolves the OTP app for a relative source path", %{root: root} do
      write_umbrella(root, "apps", [{"web-ui", "web_ui"}, {"backoffice", "bo"}])

      assert Umbrella.otp_app_for_file(root, "apps/web-ui/lib/web_ui/router.ex") == "web_ui"
      assert Umbrella.otp_app_for_file(root, "apps/backoffice/lib/bo.ex") == "bo"
    end

    test "resolves the OTP app for an absolute source path", %{root: root} do
      write_umbrella(root, "apps", [{"web-ui", "web_ui"}])

      absolute = Path.join(root, "apps/web-ui/lib/web_ui.ex")
      assert Umbrella.otp_app_for_file(root, absolute) == "web_ui"
    end

    test "honours a custom :apps_path", %{root: root} do
      write_umbrella(root, "packages", [{"web-ui", "web_ui"}])

      assert Umbrella.app_map(root) == %{"web-ui" => "web_ui"}
      assert Umbrella.otp_app_for_file(root, "packages/web-ui/lib/a.ex") == "web_ui"
      # The literal "apps" is not the apps dir here, so nothing resolves.
      assert Umbrella.otp_app_for_file(root, "apps/web-ui/lib/a.ex") == nil
    end

    test "nil for unknown children and non-umbrella paths", %{root: root} do
      write_umbrella(root, "apps", [{"web-ui", "web_ui"}])

      assert Umbrella.otp_app_for_file(root, "apps/nope/lib/a.ex") == nil
      assert Umbrella.otp_app_for_file(root, "lib/a.ex") == nil
    end

    test "accepts a pre-built {apps_path, map} context" do
      context = {"apps", %{"web-ui" => "web_ui"}}

      assert Umbrella.otp_app_for_file(context, "apps/web-ui/lib/a.ex") == "web_ui"
      assert Umbrella.otp_app_for_file(context, "apps/other/lib/a.ex") == nil
    end

    test "empty map for a single-app project", %{root: root} do
      File.mkdir_p!(root)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Single.MixProject do
        use Mix.Project
        def project, do: [app: :single, version: "0.1.0"]
      end
      """)

      assert Umbrella.app_map(root) == %{}
      assert Umbrella.otp_app_for_file(root, "lib/single.ex") == nil
    end
  end
end
