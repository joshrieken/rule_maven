defmodule RuleMaven.Workers.VoiceWorkerTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Voices.AnswerVoice
  alias RuleMaven.Workers.VoiceWorker

  defp perform(ql, voice, game) do
    VoiceWorker.perform(%Oban.Job{
      id: System.unique_integer([:positive]),
      args: %{"question_log_id" => ql.id, "voice" => voice, "game_id" => game.id}
    })
  end

  defp cached_count(ql_id),
    do: Repo.aggregate(from(v in AnswerVoice, where: v.question_log_id == ^ql_id), :count)

  describe "perform/1 refuses to restyle a non-final answer" do
    setup do
      {:ok, game} = Games.create_game(%{name: "VW Game"})
      %{game: game}
    end

    test "skips the in-flight \"Thinking...\" placeholder (no cache, no LLM)", %{game: game} do
      {:ok, ql} =
        Games.log_question(%{game_id: game.id, question: "q", answer: "Thinking..."})

      # No llm_mock set: if it tried to restyle it would error, not return :ok.
      assert :ok = perform(ql, "lawyer", game)
      assert cached_count(ql.id) == 0
    end

    test "skips a refused answer", %{game: game} do
      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          question: "q",
          answer: "The rulebook does not cover this.",
          refused: true
        })

      assert :ok = perform(ql, "lawyer", game)
      assert cached_count(ql.id) == 0
    end

    test "skips a deleted question id" do
      {:ok, game} = Games.create_game(%{name: "VW Gone"})

      assert :ok =
               VoiceWorker.perform(%Oban.Job{
                 id: 1,
                 args: %{"question_log_id" => -1, "voice" => "lawyer", "game_id" => game.id}
               })
    end
  end

  describe "kill switch" do
    test "a fresh (uncached) restyle does not call the LLM while asks_disabled is on" do
      {:ok, _} = RuleMaven.Settings.set_asks_disabled(true)

      {:ok, game} = Games.create_game(%{name: "VW KillSwitch"})

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          question: "How many dice do I roll?",
          answer: "You roll 3 dice."
        })

      # No llm_mock set: if the switch didn't short-circuit, this would hit a
      # real HTTP call instead of cleanly reporting :asks_disabled.
      assert {:error, :asks_disabled} = perform(ql, "pirate", game)
      assert cached_count(ql.id) == 0
    end
  end
end
