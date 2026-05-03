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
        assert_raise RuntimeError, ~r/^umbrella not supported in v1/, fn ->
          Mut.WorkCopy.install_overlay(work_copy, :oracle)
        end
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

  defp assert_mix(work_copy, args) do
    {output, exit_code} = mix(work_copy, args)
    assert exit_code == 0, output
  end

  defp mix(work_copy, args) do
    System.cmd("mix", args, cd: work_copy, env: env(), stderr_to_stdout: true)
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
