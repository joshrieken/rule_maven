defmodule RuleMaven.Workers.PublishCheckWorkerTest do
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, Repo, Users}
  alias RuleMaven.Workers.PublishCheckWorker

  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "pub_user_#{n}",
        email: "pub_user_#{n}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp question_fixture(attrs) do
    game = game_fixture()
    owner = user_fixture()

    base = %{
      game_id: game.id,
      user_id: owner.id,
      question: "some question",
      answer: "some answer",
      browsable: true,
      # These fixtures stand in for rows the normalize step actually rewrote —
      # which is the premise the publish gate rests on. A row that records no
      # scrub is withheld, and that is its own test below.
      question_normalized: true
    }

    {:ok, ql} =
      base
      |> Map.merge(Map.new(attrs))
      |> Games.log_question()

    ql
  end

  defp group_question_fixture(attrs) do
    owner = user_fixture()
    group = group_fixture(owner)

    attrs
    |> Map.new()
    |> Map.put_new(:group_id, group.id)
    # AskWorker only enqueues the check for rows it actually pooled, and the
    # worker's guard head now requires it — an unpooled row never surfaces
    # cross-user, so there is nothing to publish and no call worth paying for.
    |> Map.put_new(:pooled, true)
    |> then(&question_fixture(&1))
  end

  defp stub_llm(reply) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: reply, finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  # Mimics the REAL shape LLM.chat/3 returns: chat/3 decodes a JSON "answer" key
  # and falls back to "" when the reply isn't JSON, so a bare-word reply like this
  # prompt's arrives via :raw_response, with :answer empty. If `raw: true` were
  # ever dropped from the worker, this stub would make it read "" instead of "no".
  defp stub_llm_raw(reply) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "", raw_response: reply, finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp stub_llm_error do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, :timeout} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  describe "perform/1" do
    test "a clean cleaned_question becomes browsable" do
      stub_llm("no")

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == true
    end

    test "a clean cleaned_question becomes browsable (raw_response shape)" do
      stub_llm_raw("no")

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == true
    end

    test "a flagged question stays unbrowsable" do
      stub_llm("yes")

      ql =
        group_question_fixture(
          cleaned_question: "Can Dave retract his move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a missing cleaned_question stays unbrowsable and makes no LLM call" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for a row with no cleaned_question"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql = group_question_fixture(cleaned_question: nil, browsable: false)

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a skip_normalize row (cleaned_question nil, canonical_question set) never publishes and makes no LLM call" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for a skip_normalize row"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      # Mimics a skip_normalize ("Ask exactly this") row: LLM.ask/5 sets
      # cleaned = "" for skip_normalize, and AskWorker stores that as nil.
      # canonical_question is admin-curated FAQ text and unrelated to this
      # gate — it may or may not be set, but must never be read here.
      ql =
        group_question_fixture(
          cleaned_question: nil,
          canonical_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "an LLM error fails closed and lets Oban retry" do
      stub_llm_error()

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          browsable: false
        )

      assert {:error, :timeout} = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false

      run =
        Repo.get_by!(RuleMaven.Jobs.JobRun,
          scope_type: "question_log",
          scope_id: ql.id,
          kind: "publish_check"
        )

      assert run.state == "failed"
    end

    test "a garbage LLM reply fails closed" do
      stub_llm("Sure! I think no.")

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a non-group row is never touched" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for a non-group row"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql =
        question_fixture(
          group_id: nil,
          cleaned_question: "May a player retract a move?",
          browsable: true
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == true
    end

    test "an unpooled group row is never screened (no LLM call, stays unbrowsable)" do
      # mark_pooled/1 no-ops on an ungrounded citation, so a group ask can reach
      # this worker having never entered the pool. It never surfaces cross-user,
      # so screening it would be a wasted LLM call — and must never publish it.
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for an unpooled row"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          browsable: false,
          pooled: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a nonexistent row is a no-op" do
      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => -1})
    end

    # `pooled` is not consent. It is a flag the ask pipeline rewrites — AskWorker
    # re-pools a row off a `never_pool` value it read minutes earlier, so a
    # retraction could land, be undone, and this worker would find `pooled: true`
    # and publish the text of a question the crew had explicitly withdrawn. The
    # gate asks the group directly now.
    test "a row whose crew has stopped contributing does not publish" do
      stub_llm("no")

      owner = user_fixture()
      group = group_fixture(owner)

      ql =
        question_fixture(
          group_id: group.id,
          pooled: true,
          browsable: false,
          cleaned_question: "May a player retract a move?"
        )

      {:ok, _} = RuleMaven.Groups.set_contribute(group, owner, false)

      # Put the row back into the state the OLD guard would have published on:
      # pooled, unbrowsable, no retraction stamp. Only the group's live consent
      # flag now stands between it and the public browse.
      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^ql.id),
        set: [pooled: true, browsable: false, retracted_at: nil]
      )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      refute Repo.reload!(ql).browsable,
             "published a crew question after the crew turned contribution off"
    end

    # A "yes" is the system PROVING the scrub failed — it looked at the text this
    # row's answer was generated from and found a person in it. Leaving the answer
    # pooled at that exact moment was the one place the gate had hard evidence and
    # did nothing with it. The answer is the artifact that actually leaves the crew.
    test "a flagged question also PULLS THE ANSWER from the pool" do
      stub_llm("yes")

      ql =
        group_question_fixture(
          cleaned_question: "Can Marcus's wizard counterspell mine?",
          answer: "Marcus's wizard can indeed counterspell a counterspell.",
          browsable: false
        )

      assert Repo.reload!(ql).pooled, "precondition: the answer was serving the pool"

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      row = Repo.reload!(ql)
      refute row.browsable

      refute row.pooled,
             "the question was withheld for containing a name, but the answer WRITTEN FROM IT kept serving strangers"
    end

    # The answer is screened alongside the question. `recent_context` feeds the RAW
    # prior turns of a thread into the answer prompt, and the ARGUMENT-SETTLING rule
    # tells the model to name the disputing players — so a perfectly scrubbed
    # question can still produce an answer with someone's name in it.
    test "a name in the ANSWER withholds the row even when the question is clean" do
      Application.put_env(:rule_maven, :llm_mock, fn body ->
        reply = if String.contains?(inspect(body), "Persephone"), do: "yes", else: "no"
        {:ok, %{answer: "", raw_response: reply, finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          answer: "Persephone is right — a move may be retracted before the die is rolled.",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      row = Repo.reload!(ql)

      refute row.browsable,
             "published a row whose ANSWER names someone — the screen never looked at it"

      refute row.pooled
    end

    # The withdrawal stamp is checked before the LLM call, so a row retracted while
    # the job sat in the queue costs nothing to reject.
    test "a retracted row does not publish, and is not even screened" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        flunk("paid for a privacy screen on a row the crew had already withdrawn")
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      owner = user_fixture()
      group = group_fixture(owner)

      ql =
        question_fixture(
          group_id: group.id,
          pooled: true,
          browsable: false,
          cleaned_question: "May a player retract a move?"
        )

      {:ok, _} = RuleMaven.Groups.set_contribute(group, owner, false)

      # Retracted, but still flagged pooled — the pre-round-6 shape.
      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^ql.id),
        set: [pooled: true]
      )

      assert Repo.reload!(ql).retracted_at

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      refute Repo.reload!(ql).browsable
    end

    # `also_asked` is the asker's VERBATIM prose — the answer prompt asks for "the
    # exact text of the additional questions". It sits outside the
    # question/cleaned/canonical triad every other gate mediates, and nothing had
    # ever screened it. A row could clear this check on a scrubbed primary question
    # while its raw secondary one went straight to the public browse.
    test "a name in also_asked withholds the row even when the primary text is clean" do
      # "yes" for anything mentioning a person — the real prompt's job. The stub
      # answers on the blob the worker actually submits.
      Application.put_env(:rule_maven, :llm_mock, fn body ->
        text = inspect(body)
        reply = if String.contains?(text, "Persephone"), do: "yes", else: "no"
        {:ok, %{answer: "", raw_response: reply, finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql =
        group_question_fixture(
          cleaned_question: "May a player retract a move?",
          also_asked: ["and does Persephone's house rule break the endgame?"],
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      refute Repo.reload!(ql).browsable,
             "published a row whose also_asked names someone — the screen never saw it"
    end
  end
end
