defmodule RuleMaven.Extract.CalibrateTest do
  use RuleMaven.DataCase

  alias RuleMaven.Extract.Calibrate
  alias RuleMaven.Settings

  describe "materially_differed?/1" do
    test "high agreement → not material (wasted escalation)" do
      refute Calibrate.materially_differed?(0.9)
    end

    test "low agreement → material (escalation earned its cost)" do
      assert Calibrate.materially_differed?(0.5)
    end
  end

  describe "drift_sample?/0 honours the configured rate" do
    test "rate 0.0 never samples, rate 1.0 always samples" do
      Settings.put("extract_drift_sample_rate", "0.0")
      refute Enum.any?(1..50, fn _ -> Calibrate.drift_sample?() end)

      Settings.put("extract_drift_sample_rate", "1.0")
      assert Enum.all?(1..50, fn _ -> Calibrate.drift_sample?() end)
    end
  end

  describe "log/1 + waste_rate/1 + drift_rate_observed/1" do
    test "no data → nil" do
      assert Calibrate.waste_rate() == nil
      assert Calibrate.drift_rate_observed() == nil
    end

    test "waste_rate is the fraction of non-drift escalations that didn't differ" do
      # 3 escalations: 1 materially differed, 2 wasted → waste rate 2/3.
      Calibrate.log(%{materially_differed: true, drift_sample: false})
      Calibrate.log(%{materially_differed: false, drift_sample: false})
      Calibrate.log(%{materially_differed: false, drift_sample: false})
      # A drift sample must not count toward the waste rate.
      Calibrate.log(%{materially_differed: true, drift_sample: true})

      assert_in_delta Calibrate.waste_rate(), 2 / 3, 0.001
    end

    test "drift_rate_observed counts only drift samples that differed" do
      Calibrate.log(%{materially_differed: true, drift_sample: true})
      Calibrate.log(%{materially_differed: false, drift_sample: true})
      # Non-drift rows are ignored here.
      Calibrate.log(%{materially_differed: true, drift_sample: false})

      assert_in_delta Calibrate.drift_rate_observed(), 0.5, 0.001
    end

    test "rows with NULL materially_differed are excluded from the rate" do
      Calibrate.log(%{materially_differed: true, drift_sample: false})
      Calibrate.log(%{materially_differed: false, drift_sample: false})
      # A row missing the outcome (e.g. a partial/odd write) must not skew the rate.
      Calibrate.log(%{drift_sample: false})

      # Only the two real rows count: 1 wasted of 2 → 0.5.
      assert_in_delta Calibrate.waste_rate(), 0.5, 0.001
    end
  end
end
