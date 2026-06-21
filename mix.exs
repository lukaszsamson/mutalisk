defmodule Mutalisk.MixProject do
  use Mix.Project

  @version "0.1.0"

  # Public git remote confirmed at git@github.com:lukaszsamson/mutalisk.git
  # (HTTPS canonical: https://github.com/lukaszsamson/mutalisk). Update only if
  # the repo is transferred or renamed.
  @source_url "https://github.com/lukaszsamson/mutalisk"

  @description "Mutation testing for Elixir: a trustworthy, sandboxed engine " <>
                 "with coverage-based test selection, Stryker-compatible JSON " <>
                 "reports, umbrella support, and incremental cross-run history."

  @spec project() :: keyword
  def project do
    [
      app: :mutalisk,
      version: @version,
      elixir: ">= 1.19.0",
      name: "Mutalisk",
      description: @description,
      source_url: @source_url,
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      test_load_filters: [
        fn file ->
          String.ends_with?(file, "_test.exs") and not String.contains?(file, "/fixtures/")
        end
      ],
      test_ignore_filters: [~r|test/fixtures/|, ~r|test/support/|],
      application: application(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  # Hex package metadata. `priv/` is intentionally excluded — it holds only the
  # dev Dialyzer PLT and an unused schema reference; mutalisk reads no priv at
  # runtime. Implementer docs (PLAN.md, the HLD, docs/decisions, docs/spikes,
  # bench/) are excluded; only user-facing docs ship.
  @spec package() :: keyword
  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Łukasz Samson"],
      # "lib" is expanded to subtrees, excluding internal-only dev/test Mix tasks
      # under lib/mix/tasks/mut/ (e2e, test_schema, test_fallback, recompile)
      # that reference test fixtures not shipped in the package.
      files: ~w(
        lib/mut lib/mutalisk.ex
        lib/mix/tasks/mut.ex lib/mix/tasks/compile
        mix.exs README.md LICENSE CHANGELOG.md docs/MUTATORS.md
      ),
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/mutalisk"
      }
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
      # JSON: Mutalisk uses the built-in Elixir `JSON` module (Elixir 1.19+)
      # via the thin `Mut.JSON` wrapper in `lib/mut/json.ex`. No JSON
      # dependency is required at runtime, which avoids the previous
      # mutalisk -> jason -> target start-graph cycle observed when target
      # apps shared names with `:jason`'s `optional_applications`.
    ]
  end

  # ex_doc / HexDocs config. README is the landing page; the mutator catalogue
  # and changelog ship as extras. Modules are grouped by role; engine internals
  # fall under the default ungrouped list. `source_ref` is "main"; the remote
  # exists and main is pushed, so source links resolve correctly. Bump to
  # "v<version>" if tag-pinned source links are preferred.
  @spec docs() :: keyword
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/MUTATORS.md", "CHANGELOG.md"],
      source_ref: "main",
      groups_for_modules: [
        Command: [Mix.Tasks.Mut],
        Reporters: [
          Mut.Reporter.StrykerJson,
          Mut.Reporter.Terminal,
          Mut.Reporter.Html,
          Mut.Reporter.GitHubActions
        ],
        "Incremental history": [Mut.History.Store, Mut.History.Digest, Mut.History.Reuse],
        Configuration: [Mut.Config]
      ]
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
