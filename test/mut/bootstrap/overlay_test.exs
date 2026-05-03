defmodule Mut.Bootstrap.OverlayTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Bootstrap.Overlay

  test "rendered overlay is valid elixir and contains required fragments" do
    for role <- [:oracle, :schema] do
      rendered = Overlay.render(role)

      assert Code.string_to_quoted!(rendered)
      assert rendered =~ "@mutalisk_path"
      assert rendered =~ ~s("oracle" -> [:mut_oracle | compilers])
    end
  end

  test "assert_not_umbrella! detects apps_path in project" do
    work_copy = tmp_dir("umbrella")

    File.write!(
      Path.join(work_copy, "mix_user.exs"),
      "defmodule U.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: \"apps\"]\nend\n"
    )

    assert_raise RuntimeError, ~r/^umbrella not supported in v1/, fn ->
      Overlay.assert_not_umbrella!(work_copy)
    end
  end

  test "assert_not_umbrella! allows non-umbrella projects" do
    work_copy = tmp_dir("vanilla")

    File.write!(
      Path.join(work_copy, "mix_user.exs"),
      "defmodule V.MixProject do\n  use Mix.Project\n  def project, do: [app: :v]\nend\n"
    )

    assert :ok = Overlay.assert_not_umbrella!(work_copy)
  end

  defp tmp_dir(name) do
    dir = Path.expand(Path.join(["tmp", "tests", "overlay", name]))
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
