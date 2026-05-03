defmodule WithAliases.MixProject do
  use Mix.Project

  def project do
    [app: :with_aliases, version: "0.1.0", elixir: ">= 1.17.0", deps: [], aliases: aliases()]
  end

  defp aliases do
    ["test.all": ["compile"]]
  end
end
