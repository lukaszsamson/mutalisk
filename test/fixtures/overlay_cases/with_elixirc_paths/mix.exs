defmodule WithElixircPaths.MixProject do
  use Mix.Project

  def project do
    [
      app: :with_elixirc_paths,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      deps: [],
      elixirc_paths: ["lib", "src"]
    ]
  end
end
