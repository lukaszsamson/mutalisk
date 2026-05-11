defmodule Mut.EnvOracleTest do
  use ExUnit.Case, async: true

  alias Mut.EnvOracle
  alias Mut.EnvSnapshot
  alias Mut.Oracle.DispatchSite

  describe "from_snapshots/1" do
    test "indexes snapshots by {file, line, column}" do
      s1 = %EnvSnapshot{file: "lib/foo.ex", line: 10, column: 5, scope: :function_body}
      s2 = %EnvSnapshot{file: "lib/foo.ex", line: 12, column: 3, scope: :function_body}

      oracle = EnvOracle.from_snapshots([s1, s2])

      assert EnvOracle.at(oracle, "lib/foo.ex", 10, 5) == s1
      assert EnvOracle.at(oracle, "lib/foo.ex", 12, 3) == s2
      assert EnvOracle.at(oracle, "lib/foo.ex", 1, 1) == nil
    end

    test "accumulates skip-reason histogram" do
      s1 = %EnvSnapshot{
        file: "f",
        line: 1,
        column: 1,
        scope: :module_body,
        trust_level: :trusted,
        source_span: {0, 1}
      }

      s2 = %EnvSnapshot{
        file: "f",
        line: 2,
        column: 1,
        scope: :function_body,
        trust_level: :opaque
      }

      s3 = %EnvSnapshot{
        file: "f",
        line: 3,
        column: 1,
        scope: :function_body,
        trust_level: :opaque
      }

      oracle = EnvOracle.from_snapshots([s1, s2, s3])
      assert Map.get(oracle.skip_histogram, :module_body) == 1
      assert Map.get(oracle.skip_histogram, :opaque) == 2
    end

    test "eligible snapshots contribute zero to histogram" do
      s = %EnvSnapshot{
        file: "f",
        line: 1,
        column: 1,
        scope: :function_body,
        context: nil,
        trust_level: :trusted,
        source_span: {0, 5}
      }

      oracle = EnvOracle.from_snapshots([s])
      assert oracle.skip_histogram == %{}
    end
  end

  describe "body_literal_snapshots/1" do
    test "returns only the eligible snapshots" do
      s_ok = %EnvSnapshot{
        file: "f",
        line: 1,
        column: 1,
        scope: :function_body,
        context: nil,
        trust_level: :trusted,
        source_span: {0, 1}
      }

      s_opaque = %{s_ok | line: 2, trust_level: :opaque}
      s_guard = %{s_ok | line: 3, context: :guard}

      oracle = EnvOracle.from_snapshots([s_ok, s_opaque, s_guard])
      result = EnvOracle.body_literal_snapshots(oracle)
      assert result == [s_ok]
    end
  end

  describe "build_macro_index/1" do
    test "filters to macro dispatch kinds and indexes by {file, line, column, name, arity}" do
      sites = [
        %DispatchSite{
          file: "lib/foo.ex",
          line: 10,
          column: 5,
          dispatch_kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :if,
          resolved_arity: 2,
          event_file: "lib/foo.ex"
        },
        %DispatchSite{
          file: "lib/foo.ex",
          line: 11,
          column: 1,
          dispatch_kind: :remote_function,
          resolved_module: Kernel,
          resolved_name: :+,
          resolved_arity: 2,
          event_file: "lib/foo.ex"
        }
      ]

      idx = EnvOracle.build_macro_index(sites)
      assert map_size(idx) == 1
      assert Map.fetch!(idx, {"lib/foo.ex", 10, 5, :if, 2}).resolved_name == :if
      refute Map.has_key?(idx, {"lib/foo.ex", 11, 1, :+, 2})
    end

    test "empty site list produces empty index" do
      assert EnvOracle.build_macro_index([]) == %{}
    end

    test "preserves :remote_macro / :local_macro / :imported_macro" do
      for kind <- [:remote_macro, :local_macro, :imported_macro] do
        site = %DispatchSite{
          file: "f",
          line: 1,
          column: 1,
          dispatch_kind: kind,
          resolved_module: Kernel,
          resolved_name: :unless,
          resolved_arity: 2,
          event_file: "f"
        }

        idx = EnvOracle.build_macro_index([site])
        assert Map.fetch!(idx, {"f", 1, 1, :unless, 2}).kind == kind
      end
    end
  end
end
