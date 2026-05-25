defmodule Mut.Bootstrap.OverlayTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Bootstrap.Overlay

  test "rendered overlay is valid elixir and contains required fragments" do
    for role <- [:oracle, :schema] do
      rendered = Overlay.render(role)

      assert Code.string_to_quoted!(rendered)
      assert rendered =~ "@user_mod mutalisk_user_mod"
      refute rendered =~ "user_mix_module"
      assert rendered =~ "@mutalisk_path"
      assert rendered =~ ~s("oracle" -> [:mut_oracle | compilers])
    end
  end

  test "materialize installs a per-app overlay for umbrella projects" do
    work_copy = tmp_dir("umbrella")

    File.write!(
      Path.join(work_copy, "mix.exs"),
      "defmodule U.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: \"apps\"]\nend\n"
    )

    for app <- ~w(alpha beta) do
      app_dir = Path.join([work_copy, "apps", app])
      File.mkdir_p!(app_dir)

      File.write!(
        Path.join(app_dir, "mix.exs"),
        "defmodule #{String.capitalize(app)}.MixProject do\n  use Mix.Project\n  def project, do: [app: :#{app}]\nend\n"
      )
    end

    root_before = File.read!(Path.join(work_copy, "mix.exs"))
    assert :ok = Overlay.materialize(work_copy, :oracle)

    # Root is wrapped too — its deps.loadpaths must put mutalisk on the path so
    # compile.mut_oracle is discoverable in children. apps_path moves to
    # mix_user.exs; the wrapper takes mix.exs.
    assert File.read!(Path.join(work_copy, "mix_user.exs")) == root_before
    assert File.read!(Path.join(work_copy, "mix.exs")) =~ "@user_mod mutalisk_user_mod"

    for app <- ~w(alpha beta) do
      app_dir = Path.join([work_copy, "apps", app])
      assert File.exists?(Path.join(app_dir, "mix_user.exs"))
      assert File.read!(Path.join(app_dir, "mix.exs")) =~ "@user_mod mutalisk_user_mod"
    end
  end

  test "Mut.Umbrella detects apps_path and enumerates app names" do
    work_copy = tmp_dir("umbrella_detect")

    File.write!(
      Path.join(work_copy, "mix.exs"),
      "defmodule U.MixProject do\n  use Mix.Project\n  def project, do: [apps_path: \"apps\"]\nend\n"
    )

    app_dir = Path.join([work_copy, "apps", "alpha"])
    File.mkdir_p!(app_dir)

    File.write!(
      Path.join(app_dir, "mix.exs"),
      "defmodule Alpha.MixProject do\n  use Mix.Project\n  def project, do: [app: :alpha]\nend\n"
    )

    assert Mut.Umbrella.umbrella?(work_copy)
    assert Mut.Umbrella.app_names(work_copy) == ["alpha"]
  end

  test "Mut.Umbrella treats a plain project as non-umbrella" do
    work_copy = tmp_dir("vanilla")

    File.write!(
      Path.join(work_copy, "mix.exs"),
      "defmodule V.MixProject do\n  use Mix.Project\n  def project, do: [app: :v]\nend\n"
    )

    refute Mut.Umbrella.umbrella?(work_copy)
    assert Mut.Umbrella.app_names(work_copy) == []
  end

  defp tmp_dir(name) do
    dir = Path.expand(Path.join(["tmp", "tests", "overlay", name]))
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
