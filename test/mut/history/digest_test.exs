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
    test "pure-formatting churn does not change the digest" do
      a = "defmodule A do\n  def f, do: 1\nend\n"
      b = "defmodule A do\n\n  # a comment\n      def    f,   do:   1\nend"
      assert Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "semantic code change changes the digest" do
      a = "def f, do: 1"
      b = "def f, do: 2"
      refute Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "editing inside a string literal changes the digest (R4)" do
      a = ~s|def f, do: "a  b"|
      b = ~s|def f, do: "a b"|
      refute Digest.content_digest(a) == Digest.content_digest(b)
    end

    test "non-Elixir / binary content falls back to raw bytes" do
      assert Digest.content_digest(<<0, 1, 2>>) == Digest.content_digest(<<0, 1, 2>>)
      refute Digest.content_digest(<<0, 1, 2>>) == Digest.content_digest(<<0, 1, 3>>)
    end

    test "invalid UTF-8 (e.g. a gzip/binary priv asset) does not crash" do
      # `Code.string_to_quoted` runs `String.to_charlist`, which RAISES on
      # invalid UTF-8 — caught a real `project_digest` crash on a binary priv
      # file. <<0,1,2>> is valid UTF-8; a gzip header (0x1f 0x8b ...) is not.
      gz = <<0x1F, 0x8B, 0x08, 0x00, 0xC5, 0x49, 0x25, 0xE5>>
      assert is_binary(Digest.content_digest(gz))
      refute Digest.content_digest(gz) == Digest.content_digest(gz <> <<0xFF>>)
    end
  end

  describe "project_digest" do
    setup do
      root = Path.join(System.tmp_dir!(), "mut_proj_digest_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "test/support"))
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 1\nend\n")
      File.write!(Path.join(root, "test/support/helper.ex"), "defmodule H do\nend\n")
      File.write!(Path.join(root, "test/a_test.exs"), "assert A.f() == 1")
      File.write!(Path.join(root, "config/test.exs"), "import Config\n")
      File.write!(Path.join(root, "mix.lock"), "%{}\n")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "stable when nothing changes", %{root: root} do
      assert Digest.project_digest(root) == Digest.project_digest(root)
    end

    test "changes when a non-mutant lib file changes (cross-file dependency)", %{root: root} do
      before = Digest.project_digest(root)
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def f, do: 2\nend\n")
      refute Digest.project_digest(root) == before
    end

    test "changes when test support / config / mix.lock change", %{root: root} do
      for rel <- ["test/support/helper.ex", "config/test.exs", "mix.lock"] do
        before = Digest.project_digest(root)
        File.write!(Path.join(root, rel), "# changed #{rel}\n")
        refute Digest.project_digest(root) == before, "expected #{rel} to change the fingerprint"
      end
    end

    test "ignores _test.exs files (handled per-mutant by selected_tests_digest)", %{root: root} do
      before = Digest.project_digest(root)
      File.write!(Path.join(root, "test/a_test.exs"), "assert A.f() == 999")
      assert Digest.project_digest(root) == before
    end

    test "fingerprints umbrella child-app source under apps/* (R4)", %{root: root} do
      app_lib = Path.join(root, "apps/a/lib")
      File.mkdir_p!(app_lib)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 1\nend\n")

      before = Digest.project_digest(root)
      File.write!(Path.join(app_lib, "helper.ex"), "defmodule A.Helper do\n  def g, do: 2\nend\n")

      refute Digest.project_digest(root) == before,
             "editing apps/a/lib/helper.ex must change the fingerprint"
    end
  end
end
