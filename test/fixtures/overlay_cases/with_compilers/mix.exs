defmodule WithCompilers.MixProject do
  use Mix.Project

  def project do
    [
      app: :with_compilers,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      deps: [],
      compilers: Mix.compilers()
    ]
  end
end
