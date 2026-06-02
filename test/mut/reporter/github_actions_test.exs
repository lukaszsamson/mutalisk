defmodule Mut.Reporter.GitHubActionsTest do
  use ExUnit.Case, async: true

  @moduledoc "M101: GitHub Actions ::warning annotations for surviving mutants."

  alias Mut.Reporter.GitHubActions

  defp rendered do
    %{
      "files" => %{
        "lib/foo.ex" => %{
          "source" => "defmodule Foo do\n  def f(a, b), do: a < b\nend\n",
          "mutants" => [
            %{
              "status" => "Killed",
              "mutatorName" => "ComparisonBoundary",
              "description" => "replace < with <=",
              "replacement" => "a <= b",
              "location" => %{"start" => %{"line" => 2, "column" => 18}}
            },
            %{
              "status" => "Survived",
              "mutatorName" => "ComparisonNegation",
              "description" => "replace < with >=",
              "replacement" => "a >= b",
              "location" => %{"start" => %{"line" => 2, "column" => 18}}
            }
          ]
        }
      }
    }
  end

  test "emits one ::warning per surviving mutant, in workflow-command format" do
    lines = GitHubActions.render(rendered())

    assert [line] = lines
    assert line =~ ~r/^::warning file=lib\/foo\.ex,line=2,col=18::/
    assert line =~ "surviving mutant [ComparisonNegation]"
    assert line =~ "replace < with >="
    assert line =~ "a >= b"
  end

  test "no annotations when there are no survivors" do
    killed_only = %{
      "files" => %{
        "lib/foo.ex" => %{
          "source" => "x",
          "mutants" => [
            %{"status" => "Killed", "location" => %{"start" => %{"line" => 1, "column" => 1}}}
          ]
        }
      }
    }

    assert GitHubActions.render(killed_only) == []
  end

  test "escapes %, CR, LF in the message per the workflow-command spec" do
    map = %{
      "files" => %{
        "lib/p.ex" => %{
          "source" => "x",
          "mutants" => [
            %{
              "status" => "Survived",
              "mutatorName" => "M",
              "description" => "100% off\nnext line",
              "replacement" => "y",
              "location" => %{"start" => %{"line" => 1, "column" => 1}}
            }
          ]
        }
      }
    }

    [line] = GitHubActions.render(map)
    # The message portion (after the leading `::warning ...::`) must contain
    # no raw newline or bare %.
    [_prefix, message] = String.split(line, "::", parts: 2)
    refute message =~ "\n"
    assert message =~ "100%25 off"
    assert message =~ "%0A"
  end
end
