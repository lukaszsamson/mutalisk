defmodule WithMod.MixProject do
  use Mix.Project

  def project do
    [app: :with_mod, version: "0.1.0", elixir: ">= 1.17.0", deps: [], application: application()]
  end

  def application do
    [mod: {WithMod.Application, []}, extra_applications: [:logger]]
  end
end
