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
    Mut.Mutator.AtomLiteral,
    # M63: graduated for PATTERN positions only (see
    # graduated_pattern_literal_mutators/0). Its body-literal firing still
    # needs the opt-in :body_literal target, so adding it here only enables
    # IntegerLiteral-in-pattern by default — additive.
    Mut.Mutator.IntegerLiteral,
    # M79: GRADUATED. `++` -> `--` cleared the M62 gate on every matrix target
    # (jason 100%/0%, plug 100%/0%, decimal 90%/10% kill/equiv, 0% invalid) once
    # M72 dropped the crash-prone `--`->`++` and M78 excluded codegen contexts.
    # :dispatch is default-enabled, so this fires by default; additive (new
    # `++` mutants only; demo_app has no `++`, so its default plan is unchanged).
    Mut.Mutator.ConcatOperator,
    # M83: GRADUATED. `^x` -> `x` (unpin) cleared the M62 gate on 3 targets
    # (plug 14/14, absinthe 13/13, phoenix_html 1/1 — kill 100%, equiv 0%,
    # invalid 0% everywhere) after the M75 map-key hazard fixed the only invalid
    # class. :pattern_shape moves into default enabled targets to make this
    # fire by default; additive (new ^x pin mutants only).
    Mut.Mutator.Pin
  ]

  @opt_in [
    Mut.Mutator.AttributeLiteral,
    Mut.Mutator.BooleanLiteral,
    Mut.Mutator.StringLiteral,
    Mut.Mutator.FloatLiteral,
    Mut.Mutator.NilLiteral,
    Mut.Mutator.CollectionEmpty,
    Mut.Mutator.VariableReplace,
    # M69 operator-expansion (BitwiseOperator/Membership stay opt-in; M79).
    # ConcatOperator graduated to default-on (above).
    Mut.Mutator.BitwiseOperator,
    Mut.Mutator.Membership,
    # M83: Pin graduated to default-on (above).
    # M76 function-replacement (opt-in dispatch; M79 decides graduation)
    Mut.Mutator.FunctionReplace,
    # M77 conditional negate/force (opt-in `:conditional`; M79 decides graduation)
    Mut.Mutator.NegateConditional,
    # M81 statement-delete (opt-in `:statement_delete`; M83 decides graduation)
    Mut.Mutator.StatementDelete,
    # M87 clause-delete (opt-in `:clause_delete`; M88 decides graduation)
    Mut.Mutator.ClauseDelete,
    # M90 guard boolean (and<->or; not-drop). opt-in `:guard` target —
    # default-enabled, but only fires under explicit --enable guard +
    # --mutators guard_boolean until M93 decides graduation.
    Mut.Mutator.GuardBoolean
  ]

  @doc "Mutators active with no --enable/--mutators flags (default plan)."
  @spec default_on() :: [module]
  def default_on, do: @default_on

  @doc "Mutators reachable only via explicit --enable/--mutators."
  @spec opt_in() :: [module]
  def opt_in, do: @opt_in

  # M63: the literal mutators that fire in PATTERN positions by default (i.e.
  # without `--enable pattern_literal`). Only IntegerLiteral-in-pattern cleared
  # the M62 sharpened gate; the others (Atom/Nil/Boolean/String) stay opt-in
  # and fire in patterns only under explicit `--enable pattern_literal`.
  @graduated_pattern_literal [Mut.Mutator.IntegerLiteral]

  @doc "Literal mutators graduated to fire in pattern positions by default."
  @spec graduated_pattern_literal_mutators() :: [module]
  def graduated_pattern_literal_mutators, do: @graduated_pattern_literal

  @doc "Full mutator set (all tiers)."
  @spec list() :: [module]
  def list, do: @default_on ++ @opt_in

  @spec register_all() :: :ok
  def register_all do
    Enum.each(list(), &Mut.Match.Registry.register/1)
  end
end
