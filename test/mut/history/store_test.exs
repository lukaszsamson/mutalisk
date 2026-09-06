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
      project_digest: Keyword.get(opts, :project_digest, "proj"),
      killing_test: Keyword.get(opts, :killing_test),
      killing_test_file: Keyword.get(opts, :killing_test_file),
      test_timeout_ms: Keyword.get(opts, :test_timeout_ms, 10_000),
      suite_timeout_ms: Keyword.get(opts, :suite_timeout_ms)
    }
  end

  describe "path/2" do
    test "expands a relative history_path against root so cwd can't split read/write", %{dir: dir} do
      resolved = Store.path(dir, history_path: "tmp/h.json")
      assert resolved == Path.expand("tmp/h.json", dir)
      assert Path.type(resolved) == :absolute
    end

    test "passes an absolute history_path through unchanged", %{dir: dir} do
      abs = Path.join(dir, "abs.json")
      assert Store.path(dir, history_path: abs) == abs
    end
  end

  describe "round-trip" do
    test "build -> write -> load reproduces every verdict + digest", %{dir: dir} do
      path = Store.path(dir)

      records = [
        record("a", :killed,
          killing_test: "ATest works",
          killing_test_file: "test/a_test.exs",
          suite_timeout_ms: 90_000
        ),
        record("b", :survived)
      ]

      store = Store.build(:cold, records)
      assert :ok = Store.write(path, store)
      assert {:ok, loaded} = Store.load(path)

      assert loaded.generation == 1
      assert map_size(loaded.verdicts) == 2

      a = loaded.verdicts["a"]
      assert a["status"] == "killed"
      assert a["source_digest"] == "srca"
      assert a["selected_tests_digest"] == "sela"
      assert a["killing_test"] == "ATest works"
      assert a["killing_test_file"] == "test/a_test.exs"
      assert a["test_timeout_ms"] == 10_000
      assert a["suite_timeout_ms"] == 90_000
      assert a["generation"] == 1

      # An unset --suite-timeout-ms round-trips as an explicit null, not as a
      # missing key: reuse must be able to tell "no suite timeout" apart from
      # "unknown" (see the format-1 note in Mut.History.Store).
      b = loaded.verdicts["b"]
      assert Map.has_key?(b, "suite_timeout_ms")
      assert b["suite_timeout_ms"] == nil
      assert b["killing_test_file"] == nil
    end

    test "write does not overwrite a user-visible .tmp sibling", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))
      collision = path <> ".tmp"
      File.write!(collision, "KEEP")

      assert :ok = Store.write(path, Store.build(:cold, [record("a", :killed)]))

      assert File.read!(collision) == "KEEP"
      assert File.exists?(path)
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

    # A format-1 store predates `suite_timeout_ms`/`killing_test_file` in the
    # verdict entries; it is rejected wholesale rather than partially trusted.
    test "an older format_version (1) -> cold", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        ~s({"format_version": 1, "tool_version": "x", "generation": 1, "verdicts": {}})
      )

      assert {:cold, :format_version_mismatch} = Store.load(path)
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
        ~s({"format_version": 2, "tool_version": "0.0.0-not-us", "generation": 1, "verdicts": {}})
      )

      assert {:cold, :tool_version_mismatch} = Store.load(path)
    end
  end

  # F8: a version-valid store whose SHAPE is wrong used to load as `{:ok, _}`
  # and crash the pipeline (`map_size/1` on a list) after the expensive
  # baseline + coverage phases, instead of starting cold.
  defp write_store!(dir, body) do
    path = Store.path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Mut.JSON.encode!(Map.merge(valid_envelope(), body)))
    path
  end

  defp valid_envelope do
    %{
      "format_version" => 2,
      "tool_version" => to_string(Application.spec(:mutalisk, :vsn)),
      "generation" => 1,
      "verdicts" => %{}
    }
  end

  defp valid_entry do
    %{
      "status" => "killed",
      "source_digest" => "s",
      "selected_tests_digest" => "t",
      "project_digest" => "p",
      "killing_test" => nil,
      "killing_test_file" => nil,
      "test_timeout_ms" => 10_000,
      "suite_timeout_ms" => nil,
      "generation" => 1
    }
  end

  describe "cold-start safety — structurally malformed stores (F8)" do
    test "a valid envelope still loads (guards against over-rejection)", %{dir: dir} do
      path = write_store!(dir, %{"verdicts" => %{"a" => valid_entry()}})
      assert {:ok, store} = Store.load(path)
      assert map_size(store.verdicts) == 1
      assert store.generation == 1
    end

    test "verdicts as a list -> cold (the reported map_size/1 crash)", %{dir: dir} do
      path = write_store!(dir, %{"verdicts" => []})
      assert {:cold, :malformed} = Store.load(path)
    end

    test "verdicts as a string / number / null -> cold", %{dir: dir} do
      for bad <- ["nope", 7, nil] do
        path = write_store!(dir, %{"verdicts" => bad})
        assert {:cold, :malformed} = Store.load(path), "expected #{inspect(bad)} to be rejected"
      end
    end

    test "a non-integer generation -> cold", %{dir: dir} do
      for bad <- ["1", 1.5, nil, %{}] do
        path = write_store!(dir, %{"generation" => bad})
        assert {:cold, :malformed} = Store.load(path), "expected #{inspect(bad)} to be rejected"
      end
    end

    test "a missing generation / verdicts key -> cold", %{dir: dir} do
      path = write_store!(dir, %{})
      File.write!(path, Mut.JSON.encode!(Map.delete(valid_envelope(), "generation")))
      assert {:cold, :malformed} = Store.load(path)

      File.write!(path, Mut.JSON.encode!(Map.delete(valid_envelope(), "verdicts")))
      assert {:cold, :malformed} = Store.load(path)
    end

    test "a top-level array (not an object) -> cold", %{dir: dir} do
      path = Store.path(dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[]")
      assert {:cold, :format_version_mismatch} = Store.load(path)
    end
  end

  describe "entry validation (F8)" do
    test "invalid entries are dropped, valid ones survive, and the count is printed", %{dir: dir} do
      bad = %{
        # not a map
        "list" => [],
        # non-reusable status: String.to_existing_atom/record_result would break
        "error_status" => %{valid_entry() | "status" => "error"},
        "unknown_status" => %{valid_entry() | "status" => "banana"},
        # digests must be strings — a number would silently never match
        "numeric_digest" => %{valid_entry() | "source_digest" => 7},
        "missing_digest" => Map.delete(valid_entry(), "project_digest"),
        "bad_timeout" => %{valid_entry() | "test_timeout_ms" => "10000"},
        "bad_killing_test" => %{valid_entry() | "killing_test" => 42},
        "bad_generation" => %{valid_entry() | "generation" => "1"}
      }

      good = %{"keep_me" => valid_entry()}
      path = write_store!(dir, %{"verdicts" => Map.merge(bad, good)})

      {result, stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Store.load(path) end)

      assert {:ok, store} = result
      assert Map.keys(store.verdicts) == ["keep_me"]
      assert stderr =~ "dropped #{map_size(bad)} malformed verdict entries"
      assert length(String.split(stderr, "dropped")) == 2, "expected the count printed once"
    end

    test "a null/absent optional field keeps an entry reusable", %{dir: dir} do
      entry =
        valid_entry()
        |> Map.merge(%{"killing_test" => nil, "suite_timeout_ms" => nil})
        |> Map.drop(["killing_test_file", "generation"])

      path = write_store!(dir, %{"verdicts" => %{"a" => entry}})
      assert {:ok, %{verdicts: %{"a" => _}}} = Store.load(path)
    end

    test "every reusable status is accepted", %{dir: dir} do
      verdicts =
        Map.new(~w(killed survived timeout), fn status ->
          {status, %{valid_entry() | "status" => status}}
        end)

      path = write_store!(dir, %{"verdicts" => verdicts})
      assert {:ok, store} = Store.load(path)
      assert map_size(store.verdicts) == 3
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
          killing_test_file: "test/f_test.exs",
          covering_tests: ["test/f_test.exs"]
        )

      rec = Store.record_for(killed, index, read, {10_000, 60_000}, "proj-digest")
      assert rec.status == "killed"
      assert rec.killing_test == "MTest verifies f"
      assert rec.killing_test_file == "test/f_test.exs"
      assert rec.test_timeout_ms == 10_000
      assert rec.suite_timeout_ms == 60_000
      assert rec.project_digest == "proj-digest"
      assert rec.source_digest == Digest.source_digest(index, 2)

      assert rec.selected_tests_digest ==
               Digest.selected_tests_digest([{"test/f_test.exs", "assert f(1) == 1"}])
    end

    test "record_for stores a nil suite_timeout_ms when --suite-timeout-ms is unset" do
      index = Digest.function_index("defmodule M do\n  def f(x), do: x\nend\n")

      m =
        mutant(
          stable_id: "s",
          file: "lib/m.ex",
          line: 2,
          status: :survived,
          covering_tests: []
        )

      rec = Store.record_for(m, index, fn _ -> nil end, {10_000, nil}, "proj")
      assert rec.suite_timeout_ms == nil
      assert rec.killing_test_file == nil
    end

    test "record_for returns nil for non-reusable status" do
      index = Digest.function_index("defmodule M do\n  def f(x), do: x\nend\n")
      m = mutant(stable_id: "e", file: "lib/m.ex", line: 2, status: :error, covering_tests: [])
      assert Store.record_for(m, index, fn _ -> nil end, {10_000, nil}, "proj") == nil
    end
  end
end
