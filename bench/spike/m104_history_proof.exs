#!/usr/bin/env elixir
# M104 throwaway proof (design spike — NOT production code).
#
# Demonstrates the two empirical claims the M104 design rests on:
#
#   (1) FUNCTION-LEVEL source_digest isolation. Editing one function's body
#       changes that function's digest but leaves sibling functions' digests
#       byte-identical — so a per-function digest invalidates exactly the
#       mutants inside the edited function, not the whole file. A file-level
#       digest, by contrast, changes for EVERY mutant on any byte edit (it
#       would force a full re-run on a one-line change — no CI win).
#
#   (2) selected_tests_digest is order-insensitive and content-sensitive:
#       reordering the selected test list yields the same digest; changing a
#       test file's content changes it.
#
# Run: elixir bench/spike/m104_history_proof.exs
#
# This script is intentionally self-contained and disposable. The real
# implementation lives in Mut.History.Digest (M105).

defmodule M104Proof do
  # Function-level digest: hash the normalized source of every clause of a
  # named function (name/arity), keyed within its module. Mirrors the M105
  # Mut.History.Digest plan: re-parse the file, locate the enclosing def(p),
  # normalize whitespace (same normalization Mut.StableId uses), hash.
  def function_digests(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    ast
    |> collect_defs()
    |> Map.new(fn {key, clause_sources} ->
      digest =
        clause_sources
        |> Enum.map(&normalize/1)
        |> Enum.join("\n")
        |> sha()

      {key, digest}
    end)
  end

  def file_digest(source), do: source |> normalize() |> sha()

  def selected_tests_digest(entries) do
    # entries :: [{relative_path, content}]
    entries
    |> Enum.map(fn {path, content} -> {path, sha(normalize(content))} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> sha()
  end

  defp collect_defs(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {def_kind, _meta, [head | _]} = node, acc when def_kind in [:def, :defp] ->
          key = def_key(def_kind, head)
          {node, Map.update(acc, key, [Macro.to_string(node)], &[Macro.to_string(node) | &1])}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp def_key(def_kind, {:when, _, [head | _]}), do: def_key(def_kind, head)

  defp def_key(def_kind, {name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    "#{def_kind} #{name}/#{arity}"
  end

  defp def_key(def_kind, other), do: "#{def_kind} #{Macro.to_string(other)}"

  defp normalize(s), do: s |> String.trim() |> String.replace(~r/\s+/, " ")

  defp sha(bin),
    do: :sha256 |> :crypto.hash(bin) |> binary_part(0, 16) |> Base.encode16(case: :lower)
end

v1 = """
defmodule Sample do
  def alpha(x), do: x + 1

  def beta(x) do
    y = x * 2
    y - 3
  end
end
"""

# Only `beta`'s body changes (`* 2` -> `* 4`); `alpha` is byte-identical.
v2 = """
defmodule Sample do
  def alpha(x), do: x + 1

  def beta(x) do
    y = x * 4
    y - 3
  end
end
"""

d1 = M104Proof.function_digests(v1)
d2 = M104Proof.function_digests(v2)

IO.puts("# M104 proof — function-level source_digest isolation\n")
IO.puts("function digests (v1 -> v2):")

for key <- Map.keys(d1) |> Enum.sort() do
  a = d1[key]
  b = d2[key]
  flag = if a == b, do: "UNCHANGED", else: "CHANGED  "
  IO.puts("  #{flag}  #{key}")
end

alpha_stable = d1["def alpha/1"] == d2["def alpha/1"]
beta_changed = d1["def beta/1"] != d2["def beta/1"]

IO.puts("")

IO.puts(
  "file-level digest changed on the same edit?  #{M104Proof.file_digest(v1) != M104Proof.file_digest(v2)}"
)

IO.puts("")

IO.puts(
  "CLAIM 1 (function-level isolates): " <>
    if(alpha_stable and beta_changed, do: "PASS", else: "FAIL")
)

# selected_tests_digest: order-insensitive, content-sensitive.
t_a = [{"test/a_test.exs", "assert foo() == 1"}, {"test/b_test.exs", "assert bar() == 2"}]
t_a_reordered = Enum.reverse(t_a)
t_b = [{"test/a_test.exs", "assert foo() == 99"}, {"test/b_test.exs", "assert bar() == 2"}]

dig = &M104Proof.selected_tests_digest/1
order_stable = dig.(t_a) == dig.(t_a_reordered)
content_sensitive = dig.(t_a) != dig.(t_b)

IO.puts(
  "CLAIM 2 (selected_tests_digest order-insensitive + content-sensitive): " <>
    if(order_stable and content_sensitive, do: "PASS", else: "FAIL")
)

if alpha_stable and beta_changed and order_stable and content_sensitive do
  IO.puts("\nALL PROOFS PASS")
else
  System.halt(1)
end
