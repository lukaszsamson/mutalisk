defmodule LiteralsSample do
  @moduledoc """
  Standalone golden input for the env-walker literal mutators
  (String/Float/Nil/Atom/Collection). Parsed directly by
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

  def status, do: :ok

  def coords, do: {1, 2}

  def items, do: [1, 2, 3]

  def settings, do: %{a: 1, b: 2}

  def triple, do: {1, 2, 3}

  # Struct literal — M50 must NEVER empty this (it stays absent from the
  # golden). Coord need not exist; the file is parsed, not compiled.
  def point, do: %Coord{x: 1, y: 2}
end
