defmodule AppStartCallback.MixProject do
  use Mix.Project

  def project do
    [
      app: :app_start_callback,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      deps: [],
      application: application()
    ]
  end

  def application do
    [mod: {AppStartCallback, []}, extra_applications: [:logger]]
  end
end
