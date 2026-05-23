# M51 EnvWalker-consolidation proof (THROWAWAY spike — not production code).
#
# Retires the central go/no-go risk: can AstWalk's frame/path model
# subsume EnvWalker's env (scope/context/trust) classification on the
# literal-encoded AST, so the env-walker literal candidates can be emitted
# from a single frame-based traversal without changing eligibility (hence
# without churning their span-based stable IDs)?
#
# Two existing classifiers already make a "body-eligible literal" decision
# over the SAME literal-encoded AST, by DIFFERENT means:
#
#   * `Mut.AstWalk.body_literal_candidates/1` — frame/path model:
#     `body_position?(path)` from ancestor structure (the AstWalk way).
#   * `Mut.EnvWalker.collect_literal_candidates/2` — bespoke recursive
#     descent tracking scope/context/trust (the EnvWalker way).
#
# If they AGREE on which positions are body-eligible, AstWalk's model can
# carry the env-walker literals. Where they DISAGREE marks the work the
# consolidation must add (the trust/opaque-macro dimension).
#
# Run: mix run bench/spike/m51_consolidation_proof.exs

defmodule M51Proof do
  # Each fixture pairs an int/bool literal (probed by body_literal, the
  # frame/path classifier) with a string literal (probed by EnvWalker) in
  # the SAME syntactic position, so we can compare the two classifiers.
  @cases [
    {"function body (eligible)", ~S'''
     defmodule F do
       def a, do: 1
       def b, do: "s"
     end
     ''', true},
    {"guard (not eligible)", ~S'''
     defmodule F do
       def a(x) when x > 1, do: x
       def b(x) when x == "s", do: x
     end
     ''', false},
    {"function-head pattern (not eligible)", ~S'''
     defmodule F do
       def a(1), do: :ok
       def b("s"), do: :ok
     end
     ''', false},
    {"match LHS (not eligible)", ~S'''
     defmodule F do
       def a do
         1 = x()
         "s" = y()
       end
     end
     ''', false},
    {"quote body (not eligible)", ~S'''
     defmodule F do
       def a do
         quote do
           _ = 1
           _ = "s"
         end
       end
     end
     ''', false},
    {"module attribute (not eligible — AttributeLiteral owns it)", ~S'''
     defmodule F do
       @x 1
       @y "s"
     end
     ''', false},
    # The trust dimension: a literal inside an UNKNOWN macro call in a
    # function body. EnvWalker marks the descendant untrusted (skip);
    # body_position? has no trust notion.
    {"opaque-macro body (TRUST gap)", ~S'''
     defmodule F do
       def a do
         unknown_macro do
           1
         end
       end
       def b do
         unknown_macro do
           "s"
         end
       end
     end
     ''', :trust_gap}
  ]

  def run do
    IO.puts("position                                           | path-clf | env-clf | verdict")
    IO.puts(String.duplicate("-", 92))

    Enum.each(@cases, fn {label, src, expected} ->
      path_yes = body_literal_eligible?(src)
      env_yes = env_eligible?(src)
      verdict = verdict(path_yes, env_yes, expected)
      IO.puts("#{String.pad_trailing(label, 50)} | #{yn(path_yes)}      | #{yn(env_yes)}     | #{verdict}")
    end)
  end

  # path/frame classifier: does body_literal find the int/bool literal?
  defp body_literal_eligible?(src) do
    Mut.AstWalk.body_literal_candidates(file: "lib/f.ex", source: src) != []
  end

  # env classifier: does EnvWalker find the string literal as eligible?
  defp env_eligible?(src) do
    {:ok, ast} = Mut.EnvWalker.parse_string(src, "lib/f.ex")

    Mut.EnvWalker.collect_literal_candidates(ast, file: "lib/f.ex", source: src)
    |> Enum.any?(fn {c, _} -> c.syntactic_name == :__string_literal__ end)
  end

  defp verdict(p, e, :trust_gap), do: if(p != e, do: "TRUST GAP (expected: env stricter)", else: "agree")
  defp verdict(p, e, exp), do: if(p == e and p == exp, do: "agree ✓", else: "DISAGREE")

  defp yn(true), do: "yes"
  defp yn(false), do: "no "
end

M51Proof.run()
