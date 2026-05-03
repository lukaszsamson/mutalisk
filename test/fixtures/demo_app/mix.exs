defmodule DemoApp.MixProject do
  use Mix.Project

  @spec project() :: keyword
  def project do
    [
      app: :demo_app,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  @spec application() :: keyword
  def application do
    [extra_applications: [:logger]]
  end
end
