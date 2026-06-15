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
