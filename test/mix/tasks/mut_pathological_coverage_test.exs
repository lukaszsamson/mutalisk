defmodule Mix.Tasks.MutPathologicalCoverageTest do
  use ExUnit.Case, async: true

  @moduledoc """
  T48: the pathological-coverage abort message printed `wall_ms / baseline_ms`
  as "Nx threshold", but the actual abort threshold
  (`pathological_coverage_collection?/2`) is `max(baseline * 2, 10_000)`ms —
  not `baseline_ms` alone. These tests pin `pathological_threshold_ms/1` (the
  shared threshold computation) and `pathological_coverage_abort_message/2`
  (the message text) directly.
  """

  alias Mix.Tasks.Mut, as: MutTask

  describe "pathological_threshold_ms/1" do
    test "is the 10s floor below a 5s baseline (2x baseline would be 10s exactly)" do
      assert MutTask.pathological_threshold_ms(2_000) == 10_000
      assert MutTask.pathological_threshold_ms(4_999) == 10_000
    end

    test "is 2x baseline once that exceeds the 10s floor" do
      assert MutTask.pathological_threshold_ms(6_000) == 12_000
      assert MutTask.pathological_threshold_ms(30_000) == 60_000
    end

    test "matches what pathological_coverage_collection?/2 actually enforces" do
      baseline = 20_000
      threshold = MutTask.pathological_threshold_ms(baseline)

      refute MutTask.pathological_coverage_collection?(threshold, baseline)
      assert MutTask.pathological_coverage_collection?(threshold + 1, baseline)
    end
  end

  describe "pathological_coverage_abort_message/2" do
    test "reports the real threshold, not the raw baseline (T48)" do
      # baseline 3_000ms -> threshold is the 10s floor, not baseline*2 (6_000ms).
      message = MutTask.pathological_coverage_abort_message(15_000, 3_000)

      assert message =~ "took 15000ms vs baseline 3000ms"
      assert message =~ "threshold 10000ms"
      assert message =~ "1.5x threshold"
      refute message =~ "6000ms, "
    end

    test "reports the ratio against 2x baseline once that exceeds the floor" do
      # baseline 20_000ms -> threshold is baseline*2 = 40_000ms.
      message = MutTask.pathological_coverage_abort_message(100_000, 20_000)

      assert message =~ "threshold 40000ms"
      assert message =~ "2.5x threshold"
    end

    test "still mentions the fallback and static escape hatches" do
      message = MutTask.pathological_coverage_abort_message(15_000, 3_000)

      assert message =~ "--selection coverage_with_static_fallback"
      assert message =~ "--selection static"
    end
  end
end
