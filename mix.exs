defmodule Mutalisk.MixProject do
  use Mix.Project

  @spec project() :: keyword
  def project do
    [
      app: :mutalisk,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      test_load_filters: [
        fn file ->
          String.ends_with?(file, "_test.exs") and not String.contains?(file, "/fixtures/")
        end
      ],
      test_ignore_filters: [~r|test/fixtures/|, ~r|test/support/|],
      application: application(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit, :jason]
      ]
    ]
  end

  @spec application() :: keyword
  def application do
    [
      extra_applications: [:logger],
      mod: {Mut.Application, []}
    ]
  end

  @spec deps() :: [Mix.Project.dependency()]
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # runtime: false keeps :jason out of mutalisk.app's `applications` list.
      # Without this, when a target project's app name is also a name that
      # `:jason` lists in its `optional_applications` (e.g. `:decimal`),
      # Erlang's app start graph forms a cycle target -> mutalisk -> jason
      # -> target and `mix test` deadlocks at :application_controller.call/2.
      # Mutalisk only uses Jason as plain function calls (no GenServer), so
      # it does not need :jason to be a started OTP application.
      {:jason, "~> 1.4", runtime: false}
    ]
  end

  @spec aliases() :: keyword
  defp aliases do
    [
      lint: ["format --check-formatted", "compile --warnings-as-errors", "credo --strict"],
      harness: ["cmd bin/verify"]
    ]
  end
end
