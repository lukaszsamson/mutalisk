defmodule Mut.Reporter.HtmlTest do
  use ExUnit.Case, async: true

  @moduledoc "M101: self-contained HTML report of surviving mutants."

  alias Mut.Reporter.Html

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

  test "renders a self-contained HTML doc with the surviving mutant's line + mutation" do
    html = Html.render(rendered())

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<style>"
    # File + survivor surfaced.
    assert html =~ "lib/foo.ex"
    assert html =~ "ComparisonNegation"
    assert html =~ "replace &lt; with &gt;="
    assert html =~ "a &gt;= b"
    # The offending source line (line 2) is shown.
    assert html =~ "def f(a, b), do: a &lt; b"
    assert html =~ ~r/1 surviving mutant\b/
  end

  test "killed mutants are not shown; the file is omitted when fully killed" do
    html = Html.render(rendered())
    refute html =~ "ComparisonBoundary"
  end

  test "HTML-escapes source and mutation text (no injection)" do
    map = %{
      "files" => %{
        "lib/x.ex" => %{
          "source" => "a = \"<script>\"",
          "mutants" => [
            %{
              "status" => "Survived",
              "mutatorName" => "StringLiteral",
              "description" => "replace string",
              "replacement" => "\"<b>\"",
              "location" => %{"start" => %{"line" => 1, "column" => 5}}
            }
          ]
        }
      }
    }

    html = Html.render(map)
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&lt;b&gt;"
  end

  test "clean run renders a no-survivors message" do
    map = %{"files" => %{}}
    assert Html.render(map) =~ "No surviving mutants"
  end
end
