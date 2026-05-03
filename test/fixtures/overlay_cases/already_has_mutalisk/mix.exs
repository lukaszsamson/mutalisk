defmodule AlreadyHasMutalisk.MixProject do
  use Mix.Project

  def project do
    [app: :already_has_mutalisk, version: "0.1.0", elixir: ">= 1.17.0", deps: deps()]
  end

  defp deps do
    [{:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true}]
  end
end
