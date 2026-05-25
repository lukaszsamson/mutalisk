defmodule Mut.Bootstrap.Overlay.EdgeCasesTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle
  @moduletag :overlay_edge_cases

  @cases [
    "vanilla",
    "with_mod",
    "with_aliases",
    "with_compilers",
    "with_deps",
    "already_has_mutalisk",
    "with_elixirc_paths",
    "umbrella"
  ]

  test "overlay compiles supported project shapes" do
    for case_name <- @cases do
      source = Path.expand(Path.join(["test", "fixtures", "overlay_cases", case_name]))
      run_id = "overlay-#{case_name}"
      assert {:ok, work_copy} = Mut.WorkCopy.materialize(source, run_id, force: true)

      if case_name == "umbrella" do
        assert_umbrella_overlay(work_copy)
      else
        original = File.read!(Path.join(work_copy, "mix.exs"))
        assert :ok = Mut.WorkCopy.install_overlay(work_copy, :oracle)
        assert File.read!(Path.join(work_copy, "mix_user.exs")) == original

        assert_mix(work_copy, [
          "do",
          "deps.get",
          "+",
          "deps.compile",
          "--include-children",
          "mutalisk"
        ])

        assert_mix(work_copy, ["compile", "--force"])

        if case_name == "with_mod" do
          assert {output, 0} =
                   mix(work_copy, [
                     "run",
                     "-e",
                     "IO.inspect(Mix.Project.config()[:application][:mod])"
                   ])

          assert output =~ "{WithMod.Application, []}"
        end
      end
    end
  end

  # M67: umbrella support. The overlay is installed per child app (root stays
  # an untouched apps_path project); the umbrella compiles under the shared mut
  # build root; the oracle tracer fires once per app and keys sites by
  # `apps/<app>/...` (project-root-relative), not the per-app compiler cwd.
  defp assert_umbrella_overlay(work_copy) do
    root_before = File.read!(Path.join(work_copy, "mix.exs"))
    assert :ok = Mut.WorkCopy.install_overlay(work_copy, :oracle)

    # Root is wrapped too (so its deps.loadpaths puts mutalisk on the path,
    # making compile.mut_oracle discoverable in children); the apps_path
    # project moves to mix_user.exs and the rendered wrapper takes mix.exs.
    assert File.read!(Path.join(work_copy, "mix_user.exs")) == root_before
    assert File.read!(Path.join(work_copy, "mix.exs")) =~ "@user_mod mutalisk_user_mod"

    for app <- ~w(app_a app_b) do
      app_dir = Path.join([work_copy, "apps", app])
      assert File.exists?(Path.join(app_dir, "mix_user.exs"))
      assert File.read!(Path.join(app_dir, "mix.exs")) =~ "@user_mod mutalisk_user_mod"
    end

    assert_mix(work_copy, [
      "do",
      "deps.get",
      "+",
      "deps.compile",
      "--include-children",
      "mutalisk"
    ])

    assert_mix(work_copy, ["compile", "--force"], [
      {"MUTALISK_PROJECT_ROOT", Path.expand(work_copy)}
    ])

    files =
      [work_copy, "_build", "mut_oracle", ".mut_oracle.jsonl"]
      |> Path.join()
      |> oracle_site_files()

    # Sites from both apps, keyed relative to the umbrella root (no bare
    # `lib/...` collisions), and no duplicates from a re-prepended tracer.
    assert Enum.any?(files, &(&1 =~ "apps/app_a/lib/app_a.ex"))
    assert Enum.any?(files, &(&1 =~ "apps/app_b/lib/app_b.ex"))
    refute Enum.any?(files, &(&1 == "lib/app_a.ex"))
  end

  defp oracle_site_files(jsonl_path) do
    jsonl_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Mut.JSON.decode!/1)
    |> Enum.filter(&Map.has_key?(&1, "file"))
    |> Enum.map(& &1["file"])
  end

  defp assert_mix(work_copy, args, extra_env \\ []) do
    {output, exit_code} = mix(work_copy, args, extra_env)
    assert exit_code == 0, output
  end

  defp mix(work_copy, args, extra_env \\ []) do
    System.cmd("mix", args, cd: work_copy, env: env() ++ extra_env, stderr_to_stdout: true)
  end

  defp env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_oracle"},
      {"MIX_DEPS_PATH", "_build/mut_oracle/deps"},
      {"MUTALISK_ROLE", "oracle"},
      {"MUTALISK_PATH", File.cwd!()}
    ]
  end
end
