defmodule Mut.CompileRollbackTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.CompileRollback
  alias Mut.SchemaPlacer.PlacementMap

  test "diagnostic_anchors anchors on errors but NOT warnings (R10)" do
    output = """
    ** (CompileError) lib/foo.ex:5: undefined function x/0
    lib/bar.ex:7:12: warning: unused variable y
    stack line without anchor
    """

    # The warning line must NOT produce an anchor — invalidating the mutant on
    # bar.ex:7 (which only warned) when foo.ex:5 caused the error is the R10 bug.
    assert CompileRollback.diagnostic_anchors(output) == [
             %{
               file: "lib/foo.ex",
               line: 5,
               diagnostic: "** (CompileError) lib/foo.ex:5: undefined function x/0"
             }
           ]
  end

  test "diagnostic_anchors anchors a multi-line error block, skips a warning block (R10)" do
    output = """
    warning: variable "y" is unused
      │
      7 │   y = compute()
      │
      └─ lib/bar.ex:7:3

    error: undefined function x/0
      │
      5 │   x()
      │
      └─ lib/foo.ex:5:3
    """

    anchors = CompileRollback.diagnostic_anchors(output)
    assert Enum.any?(anchors, &(&1.file == "lib/foo.ex" and &1.line == 5))
    refute Enum.any?(anchors, &(&1.file == "lib/bar.ex"))
  end

  test "locate_mutants returns innermost matching range" do
    map = %PlacementMap{
      file: "lib/foo.ex",
      entries: [
        %{start_line: 1, end_line: 20, column: 1, mut_ids: [1]},
        %{start_line: 5, end_line: 8, column: 5, mut_ids: [2, 3]}
      ]
    }

    assert CompileRollback.locate_mutants(map, 6) == {:ok, [2, 3]}
    assert CompileRollback.locate_mutants(map, 10) == {:ok, [1]}
    assert CompileRollback.locate_mutants(map, 21) == :not_found
  end

  test "locate_mutants prefers a single mutant arm over an aggregate same-site range" do
    map = %PlacementMap{
      file: "lib/foo.ex",
      entries: [
        %{start_line: 10, end_line: 10, column: 5, mut_ids: [1, 2]},
        %{start_line: 10, end_line: 10, column: 15, mut_ids: [2]}
      ]
    }

    assert CompileRollback.locate_mutants(map, 10) == {:ok, [2]}
  end

  describe "umbrella diagnostic paths (T22)" do
    defp umbrella_root(apps) do
      root = Path.join(System.tmp_dir!(), "mut_rollback_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "apps"))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: "apps", version: "0.1.0"]
      end
      """)

      Enum.each(apps, fn app ->
        dir = Path.join([root, "apps", app])
        File.mkdir_p!(dir)

        File.write!(Path.join(dir, "mix.exs"), """
        defmodule #{Macro.camelize(app)}.MixProject do
          use Mix.Project
          def project, do: [app: :#{app}, version: "0.1.0"]
        end
        """)
      end)

      root
    end

    defp map_for(file), do: %PlacementMap{file: file, entries: []}

    test "an app-relative diagnostic resolves to its root-relative placement key" do
      root = umbrella_root(["foo"])
      placement_maps = %{"apps/foo/lib/bar.ex" => map_for("apps/foo/lib/bar.ex")}

      aliases = CompileRollback.file_aliases(root, placement_maps)
      assert aliases == %{"lib/bar.ex" => "apps/foo/lib/bar.ex"}

      [anchor] = CompileRollback.diagnostic_anchors("error: oops\n  └─ lib/bar.ex:12:3\n")
      assert anchor.file == "lib/bar.ex"

      canonical = CompileRollback.canonicalize_anchor(anchor, placement_maps, aliases)
      assert canonical.file == "apps/foo/lib/bar.ex"
      assert canonical.line == 12
    end

    test "an ambiguous alias (same path in two apps) is NOT resolved" do
      root = umbrella_root(["a", "b"])

      placement_maps = %{
        "apps/a/lib/x.ex" => map_for("apps/a/lib/x.ex"),
        "apps/b/lib/x.ex" => map_for("apps/b/lib/x.ex"),
        "apps/a/lib/only_a.ex" => map_for("apps/a/lib/only_a.ex")
      }

      aliases = CompileRollback.file_aliases(root, placement_maps)

      # The unambiguous key still aliases; `lib/x.ex` is dropped rather than
      # guessed at, so its anchor stays un-instrumented (not found).
      assert aliases == %{"lib/only_a.ex" => "apps/a/lib/only_a.ex"}

      anchor = %{file: "lib/x.ex", line: 3, diagnostic: "error: boom lib/x.ex:3"}
      assert CompileRollback.canonicalize_anchor(anchor, placement_maps, aliases) == anchor
    end

    test "a root-relative diagnostic keeps its direct placement key" do
      root = umbrella_root(["foo"])
      placement_maps = %{"apps/foo/lib/bar.ex" => map_for("apps/foo/lib/bar.ex")}
      aliases = CompileRollback.file_aliases(root, placement_maps)

      anchor = %{file: "apps/foo/lib/bar.ex", line: 12, diagnostic: "error: x"}
      assert CompileRollback.canonicalize_anchor(anchor, placement_maps, aliases) == anchor
    end

    test "a custom :apps_path is honoured when building the alias index" do
      root = Path.join(System.tmp_dir!(), "mut_rollback_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "packages", "foo"]))
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Up.MixProject do
        use Mix.Project
        def project, do: [apps_path: "packages", version: "0.1.0"]
      end
      """)

      File.write!(Path.join([root, "packages", "foo", "mix.exs"]), """
      defmodule Foo.MixProject do
        use Mix.Project
        def project, do: [app: :foo, version: "0.1.0"]
      end
      """)

      placement_maps = %{"packages/foo/lib/bar.ex" => map_for("packages/foo/lib/bar.ex")}

      assert CompileRollback.file_aliases(root, placement_maps) == %{
               "lib/bar.ex" => "packages/foo/lib/bar.ex"
             }
    end

    test "a single-app work copy builds no aliases" do
      root = Path.join(System.tmp_dir!(), "mut_rollback_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "mix.exs"), """
      defmodule Single.MixProject do
        use Mix.Project
        def project, do: [app: :single, version: "0.1.0"]
      end
      """)

      assert CompileRollback.file_aliases(root, %{"lib/bar.ex" => map_for("lib/bar.ex")}) == %{}
    end
  end
end
