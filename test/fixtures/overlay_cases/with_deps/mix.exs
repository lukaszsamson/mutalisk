defmodule WithDeps.MixProject do
  use Mix.Project

  def project do
    [app: :with_deps, version: "0.1.0", elixir: ">= 1.17.0", deps: deps()]
  end

  defp deps do
    [{:local_dep, path: "deps/local_dep"}]
  end
end
