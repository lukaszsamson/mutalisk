defmodule Mut.History.StoreTest do
  use ExUnit.Case, async: true

  alias Mut.History.Digest
  alias Mut.History.Store
  alias Mut.Mutant

  @tmp_root Path.join(System.tmp_dir!(), "mut_history_store_test")

  setup do
    dir = Path.join(@tmp_root, "case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp mutant(fields) do
    base = %{
      id: 0,
      engine: :fallback,
      mutator: SomeMutator,
      mutator_name: "Some",
      original_ast: nil,
      mutated_ast: nil,
      description: "d"
    }

    struct!(Mutant, Map.merge(base, Map.new(fields)))
  end

  defp record(stable_id, status, opts \\ []) do
    %{
      stable_id: stable_id,
      status: to_string(status),
      source_digest: Keyword.get(opts, :source_digest, "src#{stable_id}"),
      selected_tests_digest: Keyword.get(opts, :selected_tests_digest, "sel#{stable_id}"),
      killing_test: Keyword.get(opts, :killing_test),
      killing_test_digest: Keyword.get(opts, :killing_test_digest),
      test_timeout_ms: Keyword.get(opts, :test_timeout_ms, 10_000)
    }
  end

  describe "round-trip" do
    test "build -> write -> load reproduces every verdict + digest", %{dir: dir} do
      path = Store.path(dir)
      records = [record("a", :killed, killing_test: "test/a_test.exs"), record("b", :survived)]

      store = Store.build(:cold, records)
      assert :ok = Store.write(path, store)
      assert {:ok, loaded} = Store.load(path)

      assert loaded.generation == 1
      assert map_size(loaded.verdicts) == 2

      a = loaded.verdicts["a"]
      assert a["status"] == "killed"
      assert a["source_digest"] == "srca"
      assert a["selected_tests_digest"] == "sela"
      assert a["killing_test"] == "test/a_test.exs"
      assert a["generation"] == 1
    end

    test "generation increments across runs and merges", %{dir: dir} do
      path = Store.path(dir)

      Store.write(path, Store.build(:cold, [record("a", :killed)]))
      {:ok, gen1} = Store.load(path)
      assert gen1.generation == 1

      Store.write(path, Store.build(gen1, [record("b", :survived)]))
      {:ok, gen2} = Store.load(path)

      assert gen2.generation == 2
      # 'a' carried forward (within retention), 'b' added.
      assert Map.has_key?(gen2.verdicts, "a")
      assert Map.has_key?(gen2.verdicts, "b")
    end
  end

  describe "GC + retention" do
    test "entries not seen within retention_generations age out", %{dir: dir} do
      path = Store.path(dir)

      # Gen 1 writes 'old'. Then 3 runs that never mention it again
      # (retention default 3): old's generation is 1; floor at gen 4 is
      # 4 - 3 = 1, so gen 1 is dropped (strictly > floor required).
      store = Store.build(:cold, [record("old", :killed)])
      store = Store.build(store, [record("x1", :killed)])
      store = Store.build(store, [record("x2", :killed)])
      store = Store.build(store, [record("x3", :killed)])

      Store.write(path, store)
      {:ok, loaded} = Store.load(path)

      assert loaded.generation == 4
      refute Map.has_key?(loaded.verdicts, "old")
      assert Map.has_key?(loaded.verdicts, "x3")
    end
  end

  describe "cold-start safety" do
    test "absent file -> cold", %{dir: dir} do
      assert {:cold, :absent} = Store.load(Store.path(dir))
    end

    test "malformed file -> cold", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")
      assert {:cold, :malformed} = Store.load(path)
    end

    test "format_version mismatch -> cold", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        ~s({"format_version": 999, "tool_version": "x", "generation": 1, "verdicts": {}})
      )

      assert {:cold, :format_version_mismatch} = Store.load(path)
    end

    test "tool_version mismatch -> cold", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        ~s({"format_version": 1, "tool_version": "0.0.0-not-us", "generation": 1, "verdicts": {}})
      )

      assert {:cold, :tool_version_mismatch} = Store.load(path)
    end
  end

  describe "path" do
    test "defaults under _build/mut_history", %{dir: dir} do
      assert Store.path(dir) == Path.join([dir, "_build", "mut_history", "history.json"])
    end

    test "history_path opt overrides", %{dir: dir} do
      custom = Path.join(dir, "custom.json")
      assert Store.path(dir, history_path: custom) == custom
    end
  end

  describe "reusable_status? + record_for" do
    test "only killed/survived/timeout are reusable" do
      assert Store.reusable_status?(:killed)
      assert Store.reusable_status?(:survived)
      assert Store.reusable_status?(:timeout)
      refute Store.reusable_status?(:error)
      refute Store.reusable_status?(:invalid)
      refute Store.reusable_status?(:skipped)
    end

    test "record_for(killed) digests source + selected tests; stores killing-test id" do
      index = Digest.function_index("defmodule M do\n  def f(x), do: x\nend\n")
      read = fn "test/f_test.exs" -> "assert f(1) == 1" end

      killed =
        mutant(
          stable_id: "k",
          file: "lib/m.ex",
          line: 2,
          status: :killed,
          killing_test: "MTest verifies f",
          covering_tests: ["test/f_test.exs"]
        )

      rec = Store.record_for(killed, index, read, 10_000)
      assert rec.status == "killed"
      assert rec.killing_test == "MTest verifies f"
      assert rec.source_digest == Digest.source_digest(index, 2)

      assert rec.selected_tests_digest ==
               Digest.selected_tests_digest([{"test/f_test.exs", "assert f(1) == 1"}])
    end

    test "record_for returns nil for non-reusable status" do
      index = Digest.function_index("defmodule M do\n  def f(x), do: x\nend\n")
      m = mutant(stable_id: "e", file: "lib/m.ex", line: 2, status: :error, covering_tests: [])
      assert Store.record_for(m, index, fn _ -> nil end, 10_000) == nil
    end
  end
end
