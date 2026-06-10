defmodule Mut.ConfigTest do
  use ExUnit.Case, async: false

  @moduledoc "M100: .mutalisk.exs loading + config precedence (file < config :mut < CLI)."

  alias Mut.Config

  setup do
    root = Path.expand("tmp/tests/config/#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    # Snapshot + clear :mut app env so tests are isolated.
    saved = Application.get_all_env(:mut)

    on_exit(fn ->
      File.rm_rf!(root)
      Enum.each(Application.get_all_env(:mut), fn {k, _} -> Application.delete_env(:mut, k) end)
      Enum.each(saved, fn {k, v} -> Application.put_env(:mut, k, v) end)
    end)

    Enum.each(saved, fn {k, _} -> Application.delete_env(:mut, k) end)
    {:ok, root: root}
  end

  test "no .mutalisk.exs returns just config :mut", %{root: root} do
    Application.put_env(:mut, :fail_at, 70.0)
    config = Config.load(root)
    assert config[:fail_at] == 70.0
  end

  test "loads .mutalisk.exs as a keyword list", %{root: root} do
    File.write!(Path.join(root, ".mutalisk.exs"), """
    [selection: :static, fail_at: 50.0, concurrency: 2]
    """)

    config = Config.load(root)
    assert config[:selection] == :static
    assert config[:fail_at] == 50.0
    assert config[:concurrency] == 2
  end

  test "config :mut overrides .mutalisk.exs (file < app)", %{root: root} do
    File.write!(Path.join(root, ".mutalisk.exs"), """
    [selection: :static, fail_at: 50.0, concurrency: 2]
    """)

    Application.put_env(:mut, :fail_at, 90.0)

    config = Config.load(root)
    assert config[:fail_at] == 90.0, "config :mut must override the file"
    assert config[:selection] == :static, "file value kept when app doesn't set it"
    assert config[:concurrency] == 2
  end

  test "CLI flags override the merged file+app config (file < app < CLI)", %{root: root} do
    File.write!(Path.join(root, ".mutalisk.exs"), """
    [fail_at: 50.0, concurrency: 2]
    """)

    Application.put_env(:mut, :fail_at, 90.0)

    merged = Config.load(root)
    {:ok, opts} = Mut.Cli.parse(["--fail-at", "33.0"], merged)

    assert opts.fail_at == 33.0, "CLI must override both file and app"
    assert opts.concurrency == 2, "file value flows through when neither app nor CLI set it"
  end

  test "exclude from .mutalisk.exs is honored and compiled", %{root: root} do
    File.write!(Path.join(root, ".mutalisk.exs"), ~S"""
    [exclude: [~r"lib/foo", ~r"lib/bar"]]
    """)

    {:ok, opts} = Mut.Cli.parse([], Config.load(root))
    # R17: exclude is kept as a LIST of regexes (each preserving its own flags),
    # matched by "any pattern matches", rather than joined into one source.
    assert is_list(opts.exclude)
    any? = fn file -> Enum.any?(opts.exclude, &Regex.match?(&1, file)) end
    assert any?.("lib/foo.ex")
    assert any?.("lib/bar.ex")
    refute any?.("lib/baz.ex")
  end

  test "invalid .mutalisk.exs (not a keyword list) raises", %{root: root} do
    File.write!(Path.join(root, ".mutalisk.exs"), """
    %{not: :a_keyword_list}
    """)

    assert_raise Mix.Error, ~r/\.mutalisk\.exs is invalid/, fn -> Config.load(root) end
  end
end
