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
end
