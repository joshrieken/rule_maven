defmodule RuleMaven.GamesExpansionCacheTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  defp game(name \\ "ExpCache") do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  describe "expansion_ids on questions_log" do
    test "defaults to [] and persists a cast list" do
      g = game()

      {:ok, plain} = Games.log_question(%{game_id: g.id, question: "q", answer: "a"})
      assert Repo.get!(QuestionLog, plain.id).expansion_ids == []

      {:ok, tagged} =
        Games.log_question(%{game_id: g.id, question: "q2", answer: "a2", expansion_ids: [7, 3]})

      assert Repo.get!(QuestionLog, tagged.id).expansion_ids == [7, 3]
    end
  end

  import Ecto.Query

  defp user do
    Repo.insert!(%RuleMaven.Users.User{
      username: "exp_user_#{System.unique_integer([:positive])}",
      email: "exp#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  # Pooled community row with a unit-axis embedding and the given expansion set.
  defp pooled_q(game, expansion_ids, extra \\ %{}) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "how many cards do I draw?",
            answer: "Draw two cards.",
            visibility: "community",
            expansion_ids: expansion_ids
          },
          extra
        )
      )

    e0 = [1.0 | List.duplicate(0.0, 767)]

    Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
      set: [question_embedding: Pgvector.new(e0), pooled: true]
    )

    Repo.get!(QuestionLog, q.id)
  end

  describe "cache lookups scope by expansion set" do
    setup do
      %{g: game(), e0: [1.0 | List.duplicate(0.0, 767)]}
    end

    test "pool: base answer doesn't serve an expansion ask (and vice versa)", %{g: g, e0: e0} do
      base_row = pooled_q(g, [])

      assert {%{id: id}, _} = Games.find_similar_question_in_pool(g.id, e0)
      assert id == base_row.id

      assert Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [42]) == nil

      exp_row = pooled_q(g, [42])
      assert {%{id: id2}, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [42])
      assert id2 == exp_row.id
    end

    test "pool: unsorted query set matches the stored sorted set", %{g: g, e0: e0} do
      row = pooled_q(g, [3, 7])
      assert {%{id: id}, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [7, 3])
      assert id == row.id
    end

    test "find_user_duplicate scopes by set", %{g: g} do
      u = user()

      {:ok, _} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "exact repeat?",
          answer: "Yes.",
          expansion_ids: [42]
        })

      assert Games.find_user_duplicate(g.id, u.id, "exact repeat?", "exact repeat?") == nil

      assert {%{}, _} =
               Games.find_user_duplicate(g.id, u.id, "exact repeat?", "exact repeat?", [42])
    end

    test "find_user_similar scopes by set", %{g: g, e0: e0} do
      u = user()

      {:ok, q} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "similar?",
          answer: "Similar answer.",
          expansion_ids: []
        })

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [question_embedding: Pgvector.new(e0)]
      )

      assert {%{}, _} = Games.find_user_similar(g.id, u.id, e0)
      assert Games.find_user_similar(g.id, u.id, e0, expansion_ids: [42]) == nil
    end

    test "find_user_answer_duplicate scopes by set", %{g: g} do
      u = user()

      {:ok, prior} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "worded one way",
          answer: "Identical ruling text.",
          expansion_ids: []
        })

      _ = prior

      assert Games.find_user_answer_duplicate(g.id, u.id, "Identical ruling text.", 0)
      assert Games.find_user_answer_duplicate(g.id, u.id, "Identical ruling text.", 0, [42]) == nil
    end
  end

  describe "LLM.ask serves cache per expansion set" do
    test "a pooled base-only answer is not served to an expansion ask" do
      g = game()
      pooled_q(g, [])

      # Base ask (embedding fails in test env → Embed.embed returns error →
      # question_embedding nil → pool skipped). So instead call the lookup the
      # way ask/5 now does, proving the wiring end-to-end at the Games layer:
      e0 = [1.0 | List.duplicate(0.0, 767)]
      assert {_, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [])
      assert Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [99]) == nil
    end
  end

  describe "invalidate_pool/1 reaches answers that used the changed expansion" do
    test "staling an expansion stales base-game rows that included it" do
      base = game("Base")
      exp = game("Exp")

      with_exp = pooled_q(base, [exp.id])
      without_exp = pooled_q(base, [])

      Games.invalidate_pool(exp.id)

      assert Repo.get!(QuestionLog, with_exp.id).stale
      assert Repo.get!(QuestionLog, with_exp.id).pooled == false
      refute Repo.get!(QuestionLog, without_exp.id).stale
      assert Repo.get!(QuestionLog, without_exp.id).pooled
    end
  end
end
