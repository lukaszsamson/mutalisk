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
end
