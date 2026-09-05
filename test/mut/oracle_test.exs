defmodule Mut.OracleTest do
  use ExUnit.Case, async: false

  @moduledoc false

  setup do
    if pid = Process.whereis(Mut.Oracle), do: Agent.stop(pid)
    :ok
  end

  test "loads JSONL and validates sentinel" do
    path = tmp_file("ok.jsonl")
    File.write!(path, Mut.JSON.encode!(site()) <> "\n" <> ~s({"event":"end","count":1}\n))

    assert {:ok, 1} = Mut.Oracle.load_jsonl(path)
    assert [_site] = Mut.Oracle.lookup_by_file_line("lib/example.ex", 1)
  end

  test "missing sentinel returns error" do
    path = tmp_file("missing.jsonl")
    File.write!(path, Mut.JSON.encode!(site()) <> "\n")

    assert {:error, :missing_sentinel} = Mut.Oracle.load_jsonl(path)
  end

  test "T41 meta round-trips a real pair and a bare 2-element list value unambiguously" do
    path = tmp_file("meta_roundtrip.jsonl")

    site_with_meta = %{
      site()
      | meta: [{:line, 1}, [4, 9]]
    }

    File.write!(
      path,
      Mut.JSON.encode!(site_with_meta) <> "\n" <> ~s({"event":"end","count":1}\n)
    )

    assert {:ok, 1} = Mut.Oracle.load_jsonl(path)
    assert [decoded] = Mut.Oracle.lookup_by_file_line("lib/example.ex", 1)

    # The {key, value} pair round-trips as a pair...
    assert {:line, 1} in decoded.meta
    # ...while the bare 2-element list value round-trips as itself, NOT as a
    # decoded {key, value} pair (the T41 bug).
    assert [4, 9] in decoded.meta
  end

  test "T41 decode still accepts the old [key, value] meta pair shape" do
    path = tmp_file("meta_legacy.jsonl")

    legacy_line =
      Mut.JSON.encode!(site())
      |> Mut.JSON.decode!()
      |> Map.put("meta", [["line", 1]])
      |> Mut.JSON.encode!()

    File.write!(path, legacy_line <> "\n" <> ~s({"event":"end","count":1}\n))

    assert {:ok, 1} = Mut.Oracle.load_jsonl(path)
    assert [decoded] = Mut.Oracle.lookup_by_file_line("lib/example.ex", 1)
    assert decoded.meta == [{:line, 1}]
  end

  test "count mismatch returns error" do
    path = tmp_file("mismatch.jsonl")
    File.write!(path, Mut.JSON.encode!(site()) <> "\n" <> ~s({"event":"end","count":2}\n))

    assert {:error, :count_mismatch} = Mut.Oracle.load_jsonl(path)
  end

  defp site do
    %Mut.Oracle.DispatchSite{
      file: "lib/example.ex",
      line: 1,
      column: 3,
      dispatch_kind: :remote_function,
      resolved_module: Kernel,
      resolved_name: :+,
      resolved_arity: 2,
      event_file: "lib/example.ex"
    }
  end

  defp tmp_file(name) do
    path = Path.expand(Path.join(["tmp", "tests", "oracle", name]))
    File.mkdir_p!(Path.dirname(path))
    path
  end
end
