defmodule Mut.Mutator.Defaults do
  @moduledoc """
  Mutator tiers (M48).

    * **default-on** (`default_on/0`) — active when `mix mut` runs with no
      `--enable` and no `--mutators`: the v1 dispatch + guard mutators
      plus `AtomLiteral` (the only env-walker literal that cleared M46's
      per-target-minimum threshold). The env walker runs by default, but
      only `AtomLiteral` is active by default.
    * **opt-in** (`opt_in/0`) — every other mutator (module-attribute,
      body-literal integer/boolean, and the env-walker String/Float/Nil/
      Collection literals). Reached via an explicit `--enable <target>`
      or `--mutators <name>`.
    * **presets** — deferred (M46: only one literal is default-on; a
      `--enable literal` preset needs ≥2 candidates).

  `list/0` is the full set, used to register every mutator's
  compatibility predicate with `Mut.Match.Registry` regardless of tier.
  """

  @default_on [
    Mut.Mutator.Arithmetic,
    Mut.Mutator.ComparisonBoundary,
    Mut.Mutator.ComparisonNegation,
    Mut.Mutator.Boolean,
    Mut.Mutator.UnaryNot,
    Mut.Mutator.GuardComparisonBoundary,
    Mut.Mutator.GuardComparisonNegation,
    Mut.Mutator.GuardTypeTest,
    Mut.Mutator.AtomLiteral
  ]

  @opt_in [
    Mut.Mutator.AttributeLiteral,
    Mut.Mutator.IntegerLiteral,
    Mut.Mutator.BooleanLiteral,
    Mut.Mutator.StringLiteral,
    Mut.Mutator.FloatLiteral,
    Mut.Mutator.NilLiteral,
    Mut.Mutator.CollectionEmpty,
    Mut.Mutator.VariableReplace
  ]

  @doc "Mutators active with no --enable/--mutators flags (default plan)."
  @spec default_on() :: [module]
  def default_on, do: @default_on

  @doc "Mutators reachable only via explicit --enable/--mutators."
  @spec opt_in() :: [module]
  def opt_in, do: @opt_in

  @doc "Full mutator set (all tiers)."
  @spec list() :: [module]
  def list, do: @default_on ++ @opt_in

  @spec register_all() :: :ok
  def register_all do
    Enum.each(list(), &Mut.Match.Registry.register/1)
  end
end
