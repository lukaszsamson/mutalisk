defmodule Mut.Worker.Persistent.DetectorTest do
  use ExUnit.Case, async: true

  alias Mut.Worker.Persistent.Detector

  describe "detect_in_apps/1" do
    test "returns empty list for clean app set" do
      assert Detector.detect_in_apps([:elixir, :logger, :plug_crypto]) == []
    end

    test "fires :mox signature on :mox dep" do
      assert [{:mox, msg}] = Detector.detect_in_apps([:mox, :elixir])
      assert msg =~ "Mox-class"
    end

    test "fires :ecto signature on :ecto dep" do
      assert [{:ecto, msg}] = Detector.detect_in_apps([:ecto])
      assert msg =~ "Ecto-class"
    end

    test "fires :ecto signature on :ecto_sql dep (still a single ecto entry)" do
      assert [{:ecto, _}] = Detector.detect_in_apps([:ecto_sql])
    end

    test "collapses :ecto + :ecto_sql into a single entry" do
      detections = Detector.detect_in_apps([:ecto, :ecto_sql])
      assert length(detections) == 1
      assert [{:ecto, _}] = detections
    end

    test "fires :gettext signature on :gettext dep" do
      assert [{:gettext, msg}] = Detector.detect_in_apps([:gettext])
      assert msg =~ "Gettext-class"
    end

    test "fires multiple signatures when multiple deps present" do
      detections = Detector.detect_in_apps([:mox, :ecto, :gettext])
      sigs = Enum.map(detections, fn {sig, _} -> sig end) |> Enum.sort()
      assert sigs == [:ecto, :gettext, :mox]
    end
  end

  describe "format_warning/1" do
    test "produces a single-line stderr-shaped warning" do
      [detection] = Detector.detect_in_apps([:mox])
      line = Detector.format_warning(detection)
      assert is_binary(line)
      refute String.contains?(line, "\n")
      assert line =~ "[mutalisk]"
      assert line =~ "--worker-type mix"
      assert line =~ "PERSISTENT_WORKER_GUIDE.md"
    end
  end

  describe "detect/1 against fixture sandboxes" do
    @tag :tmp_dir
    test "reads compiled-dep tree under _build/mut_schema/lib/<app>/ebin", %{tmp_dir: dir} do
      mox_ebin = Path.join([dir, "_build/mut_schema/lib/mox/ebin"])
      File.mkdir_p!(mox_ebin)
      File.write!(Path.join(mox_ebin, "mox.app"), "{application, mox, []}.")

      assert [{:mox, _}] = Detector.detect(dir)
    end

    @tag :tmp_dir
    test "silent on non-flagged deps", %{tmp_dir: dir} do
      ebin = Path.join([dir, "_build/mut_schema/lib/plug_crypto/ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "plug_crypto.app"), "{application, plug_crypto, []}.")

      assert Detector.detect(dir) == []
    end

    @tag :tmp_dir
    test "silent when sandbox has no compiled deps yet", %{tmp_dir: dir} do
      assert Detector.detect(dir) == []
    end
  end
end
