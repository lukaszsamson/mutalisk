defmodule Mut.Worker.PersistentRunner.ResetTest do
  use ExUnit.Case, async: false

  alias Mut.Worker.PersistentRunner.Reset

  describe "Application env" do
    test "restores values that diverged and drops keys the mutant added" do
      # :mutalisk is the host app under test; its env is non-system and
      # safe to mutate. System apps (kernel, stdlib, logger, ...) are
      # intentionally not snapshot/reset by Reset to avoid disturbing
      # the OTP runtime; that exclusion is verified separately below.
      Application.put_env(:mutalisk, :_m19_baseline_key, :baseline, persistent: true)
      baseline = Reset.capture_app_env()

      Application.put_env(:mutalisk, :_m19_baseline_key, :poisoned, persistent: true)
      Application.put_env(:mutalisk, :_m19_added_key, :added, persistent: true)

      assert :ok = Reset.reset_app_env(baseline)

      assert Application.get_env(:mutalisk, :_m19_baseline_key) == :baseline
      refute Keyword.has_key?(Application.get_all_env(:mutalisk), :_m19_added_key)

      Application.delete_env(:mutalisk, :_m19_baseline_key, persistent: true)
    end

    test "system apps are excluded from the snapshot" do
      baseline = Reset.capture_app_env()

      refute Map.has_key?(baseline, :kernel)
      refute Map.has_key?(baseline, :stdlib)
      refute Map.has_key?(baseline, :elixir)
      refute Map.has_key?(baseline, :logger)
      refute Map.has_key?(baseline, :ex_unit)
    end
  end

  describe "ETS tables" do
    test "deletes tables created after the snapshot, leaves baseline tables alone" do
      pre_existing = :ets.new(:_m19_pre, [:public])
      baseline = Reset.capture_ets_tables()

      mutant_added = :ets.new(:_m19_added, [:public])

      assert mutant_added in :ets.all()

      assert :ok = Reset.reset_ets_tables(baseline)

      refute mutant_added in :ets.all()
      assert pre_existing in :ets.all()

      :ets.delete(pre_existing)
    end
  end

  describe "registered processes" do
    test "kills processes registered after the snapshot, leaves earlier ones" do
      old_pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(old_pid, :_m19_old_proc)

      baseline = Reset.capture_registered()

      new_pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(new_pid, :_m19_new_proc)

      assert :_m19_new_proc in Process.registered()

      assert :ok = Reset.reset_registered(baseline)

      Process.sleep(50)
      refute :_m19_new_proc in Process.registered()
      assert :_m19_old_proc in Process.registered()

      Process.exit(old_pid, :kill)
    end
  end

  describe "persistent_term" do
    test "erases keys added after the snapshot, preserves the listed keys" do
      :persistent_term.put({:_m19, :pre}, :baseline)
      baseline = Reset.capture_persistent_terms()

      :persistent_term.put({:_m19, :added}, :added)
      :persistent_term.put({:_m19, :preserved}, :preserve_me)

      assert :persistent_term.get({:_m19, :added}) == :added

      assert :ok = Reset.reset_persistent_terms(baseline, [{:_m19, :preserved}])

      assert_raise ArgumentError, fn -> :persistent_term.get({:_m19, :added}) end
      assert :persistent_term.get({:_m19, :pre}) == :baseline
      assert :persistent_term.get({:_m19, :preserved}) == :preserve_me

      :persistent_term.erase({:_m19, :pre})
      :persistent_term.erase({:_m19, :preserved})
    end
  end

  describe "ExUnit OnExitHandler" do
    test "clearing the table is a safe no-op even when ExUnit isn't started" do
      assert :ok = Reset.clear_on_exit_handler()
    end
  end
end
