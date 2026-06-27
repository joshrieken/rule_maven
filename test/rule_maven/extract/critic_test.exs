defmodule RuleMaven.Extract.CriticTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.Critic

  describe "verify/3" do
    test "clean on first pass → verified, no re-transcribe" do
      critique = fn _img, _text -> {:ok, []} end
      transcribe = fn _img, _g -> flunk("should not re-transcribe a clean page") end

      r = Critic.verify("img", "good text", critique_fn: critique, transcribe_fn: transcribe)

      assert r.verified?
      assert r.residual_defects == []
      assert r.rounds == 0
      assert r.text == "good text"
    end

    test "defect → repair → clean → verified" do
      # First critique finds a defect, second (after repair) is clean.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      critique = fn _img, _text ->
        n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:ok, ["MISSING: the scoring sidebar"]}, else: {:ok, []}
      end

      transcribe = fn _img, guidance ->
        assert guidance =~ "scoring sidebar"
        {:ok, "good text + scoring sidebar"}
      end

      r = Critic.verify("img", "good text", critique_fn: critique, transcribe_fn: transcribe)

      assert r.verified?
      assert r.text == "good text + scoring sidebar"
      assert r.rounds == 1
    end

    test "defects persist past max_rounds → unverified with residual" do
      critique = fn _img, _text -> {:ok, ["WRONG NUMBER: says 5, image shows 6"]} end
      transcribe = fn _img, _g -> {:ok, "still wrong"} end

      r =
        Critic.verify("img", "candidate",
          critique_fn: critique,
          transcribe_fn: transcribe,
          max_rounds: 2
        )

      refute r.verified?
      assert r.residual_defects == ["WRONG NUMBER: says 5, image shows 6"]
      assert r.rounds == 2
    end

    test "critic failure never blocks — keeps candidate, marks unverified" do
      critique = fn _img, _text -> {:error, :timeout} end
      transcribe = fn _img, _g -> flunk("should not re-transcribe when critic errors") end

      r = Critic.verify("img", "candidate", critique_fn: critique, transcribe_fn: transcribe)

      refute r.verified?
      assert r.text == "candidate"
      assert r.residual_defects == []
    end

    test "empty repair is rejected — keeps candidate, reports defects" do
      critique = fn _img, _text -> {:ok, ["MISSING: a table row"]} end
      transcribe = fn _img, _g -> {:ok, "   "} end

      r = Critic.verify("img", "candidate", critique_fn: critique, transcribe_fn: transcribe)

      refute r.verified?
      assert r.text == "candidate"
      assert r.residual_defects == ["MISSING: a table row"]
    end

    test "re-transcribe error → keeps candidate with defects" do
      critique = fn _img, _text -> {:ok, ["HALLUCINATED: invented rule"]} end
      transcribe = fn _img, _g -> {:error, :rate_limited} end

      r = Critic.verify("img", "candidate", critique_fn: critique, transcribe_fn: transcribe)

      refute r.verified?
      assert r.text == "candidate"
      assert r.residual_defects == ["HALLUCINATED: invented rule"]
    end
  end
end
