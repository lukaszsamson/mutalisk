defmodule Mutalisk.MixProject do
  use Mix.Project

  @spec project() :: keyword
  def project do
    [
      app: :mutalisk,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r|test/fixtures/|],
      application: application(),
      deps: deps(),
      aliases: aliases()
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
      {:jason, "~> 1.4"}
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
