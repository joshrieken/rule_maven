defmodule RuleMaven.Workers.AskWorkerDedupTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Workers.AskWorker

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  test "same-user duplicate deletes the provisional row and broadcasts a redirect" do
    {:ok, game} = Games.create_game(%{name: "DedupGame"})
    u = user("dedup_u")

    # The asker's existing answer (the redirect target).
    {:ok, source} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Roll 3 dice.",
        cleaned_question: "how many dice do i roll?",
        visibility: "private"
      })

    # The provisional row the LiveView pre-logged for the re-ask.
    {:ok, prov} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Thinking...",
        visibility: "private"
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    assert_received {:ask_redirect, %{question_log_id: pid, source_question_log_id: sid}}
    assert pid == prov.id
    assert sid == source.id

    # Provisional gone, source intact, no second copy persisted.
    refute Repo.get(QuestionLog, prov.id)
    assert Repo.get(QuestionLog, source.id)
    assert Repo.aggregate(QuestionLog, :count) == 1
  end

  test "a fresh answer identical to the asker's own prior answer redirects" do
    {:ok, game} = Games.create_game(%{name: "AnsDedupGame"})
    u = user("ans_dedup")

    # A differently-worded prior question whose answer the fresh ask will match.
    {:ok, prior} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "how does a turn go?",
        answer: "Roll 3 dice, then move.",
        visibility: "private"
      })

    {:ok, prov} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "explain the turn sequence",
        answer: "Thinking...",
        visibility: "private"
      })

    # No cache hit (distinct question, no embeddings) → the LLM "answers"; mock it
    # to return the SAME text as the prior answer so answer-dedup fires.
    Application.put_env(:rule_maven, :llm_mock, fn _ ->
      {:ok,
       %{answer: "Roll 3 dice, then move.", cited_passage: "p.1", followup: false, followups: []}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "explain the turn sequence",
               "user_id" => u.id
             })

    assert_received {:ask_redirect, %{question_log_id: pid, source_question_log_id: sid}}
    assert pid == prov.id
    assert sid == prior.id
    refute Repo.get(QuestionLog, prov.id)
    assert Repo.aggregate(QuestionLog, :count) == 1
  end

  test "falls back to a normal stored answer when the source was deleted" do
    {:ok, game} = Games.create_game(%{name: "DedupGoneGame"})
    u = user("dedup_gone")

    {:ok, source} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Roll 3 dice.",
        cleaned_question: "how many dice do i roll?",
        visibility: "private"
      })

    {:ok, prov} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Thinking...",
        visibility: "private"
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    # Source vanishes between the cache hit and the worker writing — the worker
    # must still produce a usable answer on the provisional row.
    Games.delete_question(source)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    refute_received {:ask_redirect, _}
    # Provisional row survived and was filled (still exists).
    assert Repo.get(QuestionLog, prov.id)
  end
end
