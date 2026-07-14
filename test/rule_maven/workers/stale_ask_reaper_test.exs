defmodule RuleMaven.Workers.StaleAskReaperTest do
  @moduledoc """
  The reaper writes "⚠️" over a row. That makes its NEGATIVE cases the important
  ones: reaping a row whose ask is merely slow would destroy a real answer that
  was about to arrive. Most of these tests assert it leaves things alone.
  """
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{Games, Repo, Users}
  alias RuleMaven.Workers.{AskWorker, StaleAskReaper}

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "reap_#{n}",
        email: "reap_#{n}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp game_fixture do
    {:ok, g} = Games.create_game(%{name: "Reaper #{System.unique_integer([:positive])}"})
    g
  end

  # A row pre-logged by the ask path and never finished. `ago` in minutes.
  defp thinking_row(game, ago, attrs \\ %{}) do
    inserted = DateTime.utc_now() |> DateTime.add(-ago, :minute) |> DateTime.truncate(:second)

    base = %{
      game_id: game.id,
      user_id: user_fixture().id,
      question: "How do I win this game?",
      answer: "Thinking...",
      visibility: "private",
      expansion_ids: [],
      inserted_at: inserted,
      updated_at: inserted
    }

    Repo.insert!(struct!(QuestionLog, Map.merge(base, attrs)))
  end

  defp live_job(ql, state) do
    Repo.insert!(
      AskWorker.new(%{question_log_id: ql.id, game_id: ql.game_id, question: ql.question})
      |> Ecto.Changeset.change(%{state: state, scheduled_at: DateTime.utc_now()})
    )
  end

  defp run, do: perform_job(StaleAskReaper, %{})

  describe "reaping" do
    test "finalizes a row stranded past the grace window with no job left" do
      game = game_fixture()
      ql = thinking_row(game, 45)

      assert :ok = run()

      reaped = Repo.get!(QuestionLog, ql.id)

      # The same terminal shape a crashed ask produces — so the UI's existing
      # retry button and auto-flag path pick it up with no special-casing.
      assert reaped.answer =~ "⚠️"
      assert reaped.error_kind == "unknown"
    end

    test "an already-terminal row is never touched" do
      game = game_fixture()
      good = thinking_row(game, 45, %{answer: "You win at 10 points.", citation_valid: true})

      assert :ok = run()

      assert Repo.get!(QuestionLog, good.id).answer == "You win at 10 points."
      assert is_nil(Repo.get!(QuestionLog, good.id).error_kind)
    end
  end

  describe "rows it must NOT reap" do
    test "a row still inside the grace window — the ask may simply be slow" do
      game = game_fixture()
      ql = thinking_row(game, 5)

      assert :ok = run()

      assert Repo.get!(QuestionLog, ql.id).answer == "Thinking..."
    end

    for state <- ~w(available scheduled executing retryable) do
      test "an old row whose job is still #{state} — a backlog is not a crash" do
        game = game_fixture()
        ql = thinking_row(game, 120)
        live_job(ql, unquote(state))

        assert :ok = run()

        # Reaping this would overwrite an answer that is about to be written.
        assert Repo.get!(QuestionLog, ql.id).answer == "Thinking..."
        assert is_nil(Repo.get!(QuestionLog, ql.id).error_kind)
      end
    end

    test "a row whose job finished terminally IS reaped — that job will never write it" do
      game = game_fixture()
      ql = thinking_row(game, 45)
      live_job(ql, "discarded")

      assert :ok = run()

      assert Repo.get!(QuestionLog, ql.id).error_kind == "unknown"
    end
  end

  describe "guards" do
    test "caps how many rows one tick may rewrite" do
      game = game_fixture()
      RuleMaven.Settings.put("stale_ask_max_rows", "2")
      on_exit(fn -> RuleMaven.Settings.put("stale_ask_max_rows", "") end)

      for _ <- 1..5, do: thinking_row(game, 45)

      assert :ok = run()

      # A backstop, not a bulk rewrite: hundreds of stranded rows means something
      # else is broken, and the cap stops one bad tick from defacing the table.
      still_thinking =
        Repo.all(from q in QuestionLog, where: q.game_id == ^game.id and q.answer == "Thinking...")

      assert length(still_thinking) == 3
    end

    test "is idempotent — a second tick finds nothing" do
      game = game_fixture()
      thinking_row(game, 45)

      assert :ok = run()
      assert StaleAskReaper.stranded() == []
      assert :ok = run()
    end
  end
end
