defmodule LiteralsSample do
  @moduledoc """
  Standalone golden input for the env-walker literal mutators
  (StringLiteral / FloatLiteral / NilLiteral). Parsed directly by
  `Mut.Mutator.GoldenMutationsTest`; NOT under `demo_app/lib`, so the
  demo_app oracle build never compiles it and demo_app stable IDs stay
  byte-identical (M44 acceptance). Each function body holds one
  trusted literal in normal (non-match, non-guard) context.
  """

  def pi, do: 3.14

  def origin_float, do: 0.0

  def greeting, do: "hello"

  def already_x, do: "x"

  def nothing, do: nil
end
