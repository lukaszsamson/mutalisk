defmodule Mut.TestSelection.StaticTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.TestSelection.Static

  test "analyze captures static module reference shapes" do
    path =
      write_test("references", """
      defmodule StaticReferencesTest do
        use ExUnit.Case, async: true
        alias Sample.AliasRef
        alias Sample.OriginalRef, as: RenamedRef
        import Sample.ImportRef, only: [value: 0]
        require Sample.RequireRef
        use Sample.UseRef
        @behaviour Sample.BehaviourRef

        test "refs" do
          Sample.RemoteRef.value()
          fun = &Sample.CaptureRef.value/1
          apply(Sample.ApplyRef, :value, [])
          Kernel.apply(Sample.KernelApplyRef, :value, [])
          :erlang.apply(Sample.ErlangApplyRef, :value, [])
          assert is_function(fun, 1)
        end
      end
      """)

    analysis = Static.analyze([Path.dirname(path)])

    for module <- [
          Sample.AliasRef,
          Sample.OriginalRef,
          Sample.ImportRef,
          Sample.RequireRef,
          Sample.UseRef,
          Sample.BehaviourRef,
          Sample.RemoteRef,
          Sample.CaptureRef,
          Sample.ApplyRef,
          Sample.KernelApplyRef,
          Sample.ErlangApplyRef
        ] do
      assert Map.fetch!(analysis.index, module) == MapSet.new([path])
    end
  end

  test "analyze identifies dynamic dispatch files" do
    apply_path =
      write_test("dynamic_apply", """
      defmodule DynamicApplyTest do
        use ExUnit.Case, async: true

        test "dynamic apply" do
          module = Sample.Dynamic
          args = []
          apply(module, :value, args)
        end
      end
      """)

    concat_path =
      write_test("dynamic_concat", """
      defmodule DynamicConcatTest do
        use ExUnit.Case, async: true

        test "dynamic concat" do
          Module.concat([Sample, Dynamic]).value()
        end
      end
      """)

    remote_path =
      write_test("dynamic_remote", """
      defmodule DynamicRemoteTest do
        use ExUnit.Case, async: true

        test "dynamic remote" do
          module = Sample.Dynamic
          module.value()
        end
      end
      """)

    analysis = Static.analyze([Path.dirname(Path.dirname(apply_path))])

    assert MapSet.subset?(
             MapSet.new([apply_path, concat_path, remote_path]),
             analysis.dynamic_dispatch_files
           )
  end

  test "analyze skips references inside quote blocks" do
    path =
      write_test("quoted", """
      defmodule QuotedTest do
        use ExUnit.Case, async: true

        test "quote" do
          quote do
            Sample.Quoted.value()
          end
        end
      end
      """)

    analysis = Static.analyze([Path.dirname(path)])

    refute Map.has_key?(analysis.index, Sample.Quoted)
  end

  test "covering_tests returns indexed tests for a known module" do
    paths = ["test/sample_test.exs", "test/other_test.exs"]

    analysis = %{
      index: %{Sample.Known => MapSet.new(["test/sample_test.exs"])},
      dynamic_dispatch_files: MapSet.new()
    }

    assert Static.covering_tests(analysis, Sample.Known, paths) == ["test/sample_test.exs"]
  end

  test "covering_tests includes prefix module references" do
    paths = ["test/sample_test.exs", "test/other_test.exs"]

    analysis = %{
      index: %{Sample => MapSet.new(["test/sample_test.exs"])},
      dynamic_dispatch_files: MapSet.new()
    }

    assert Static.covering_tests(analysis, Sample.Known, paths) == ["test/sample_test.exs"]
  end

  test "covering_tests adds convention mirror test files" do
    paths = ["/repo/test/sample/known_test.exs", "/repo/test/unrelated_test.exs"]
    analysis = %{index: %{}, dynamic_dispatch_files: MapSet.new()}

    assert Static.covering_tests(analysis, Sample.Known, paths) == [
             "/repo/test/sample/known_test.exs"
           ]
  end

  test "covering_tests adds module test suffix files" do
    paths = ["test/sample_test.exs", "test/other_test.exs"]

    analysis = %{
      index: %{SampleTest.Nested => MapSet.new(["test/sample_test.exs"])},
      dynamic_dispatch_files: MapSet.new()
    }

    assert Static.covering_tests(analysis, Sample, paths) == ["test/sample_test.exs"]
  end

  test "covering_tests includes dynamic dispatch files for every module" do
    paths = ["test/dynamic_test.exs", "test/other_test.exs"]

    analysis = %{
      index: %{},
      dynamic_dispatch_files: MapSet.new(["test/dynamic_test.exs"])
    }

    assert Static.covering_tests(analysis, Any.Module, paths) == ["test/dynamic_test.exs"]
  end

  test "covering_tests falls back to all tests when no dependency is known" do
    paths = ["test/a_test.exs", "test/b_test.exs"]
    analysis = %{index: %{}, dynamic_dispatch_files: MapSet.new()}

    assert Static.covering_tests(analysis, Unknown.Module, paths) == paths
  end

  defp write_test(name, source) do
    path = Path.expand(Path.join(["tmp", "tests", "test_selection", name, "sample_test.exs"]))
    File.rm_rf!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end
end
