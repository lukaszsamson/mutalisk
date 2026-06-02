defmodule Mut.History.DigestTest do
  use ExUnit.Case, async: true

  alias Mut.History.Digest

  @v1 """
  defmodule Sample do
    def alpha(x), do: x + 1

    def beta(x) do
      y = x * 2
      y - 3
    end

    @answer 42
  end
  """

  # Only beta's body changes (`* 2` -> `* 4`); alpha + the attribute unchanged.
  @v2 """
  defmodule Sample do
    def alpha(x), do: x + 1

    def beta(x) do
      y = x * 4
      y - 3
    end

    @answer 42
  end
  """

  defp lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
  end

  defp line_of(source, needle) do
    {_text, n} = Enum.find(lines(source), fn {text, _n} -> String.contains?(text, needle) end)
    n
  end

  describe "source_digest — function-level isolation" do
    test "editing one function changes only that function's mutants' digest" do
      i1 = Digest.function_index(@v1)
      i2 = Digest.function_index(@v2)

      alpha_line = line_of(@v1, "def alpha")
      beta_line = line_of(@v1, "y = x")

      assert Digest.source_digest(i1, alpha_line) == Digest.source_digest(i2, alpha_line)
      refute Digest.source_digest(i1, beta_line) == Digest.source_digest(i2, beta_line)
    end

    test "non-function-scoped line falls back to a stable whole-file digest" do
      i1 = Digest.function_index(@v1)
      attr_line = line_of(@v1, "@answer")
      # The attribute line is in no def -> file digest. Same on a re-index.
      assert Digest.source_digest(i1, attr_line) ==
               Digest.source_digest(Digest.function_index(@v1), attr_line)
    end

    test "whitespace-only churn does not change a function digest" do
      reindented = String.replace(@v1, "    y = x * 2", "        y = x * 2")
      beta_line = line_of(@v1, "y = x")

      assert Digest.source_digest(Digest.function_index(@v1), beta_line) ==
               Digest.source_digest(Digest.function_index(reindented), beta_line)
    end

    test "unparseable source degrades to a file-only index (no crash)" do
      index = Digest.function_index("defmodule Broken do def foo(")
      assert is_binary(Digest.source_digest(index, 1))
    end
  end

  describe "selected_tests_digest" do
    test "order-insensitive, content-sensitive" do
      a = [{"test/a_test.exs", "assert foo() == 1"}, {"test/b_test.exs", "assert bar() == 2"}]
      reordered = Enum.reverse(a)

      changed = [
        {"test/a_test.exs", "assert foo() == 99"},
        {"test/b_test.exs", "assert bar() == 2"}
      ]

      assert Digest.selected_tests_digest(a) == Digest.selected_tests_digest(reordered)
      refute Digest.selected_tests_digest(a) == Digest.selected_tests_digest(changed)
    end

    test "empty selection is a stable digest" do
      assert Digest.selected_tests_digest([]) == Digest.selected_tests_digest([])
    end
  end

  describe "content_digest" do
    test "whitespace-normalized" do
      assert Digest.content_digest("a  b\n\tc") == Digest.content_digest("a b c")
    end
  end
end
