defmodule AppB.MixProject do
  use Mix.Project

  def project do
    [
      app: :app_b,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      deps: deps()
    ]
  end

  defp deps do
    [{:app_a, in_umbrella: true}]
  end
end
