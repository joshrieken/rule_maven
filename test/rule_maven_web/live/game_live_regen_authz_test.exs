defmodule RuleMavenWeb.GameLiveRegenAuthzTest do
  @moduledoc """
  LiveView events are forgeable. `grouped_questions/1` puts every community row
  into every viewer's conversation, so the chat page must re-check ownership
  server-side before regenerating (which DELETES the old row) and before voting.
  """
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  # The owner path reaches Oban.insert (a real re-ask is enqueued), which needs
  # a named instance to insert against. Same pattern as trust_test.exs.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_#{System.unique_integer([:positive])}",
            email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  test "a forged regenerate cannot delete another user's community answer", %{conn: conn} do
    author = create_user("regen_author")
    attacker = create_user("regen_attacker")
    game = published_game_fixture(%{name: "Regen Authz Game"})

    {:ok, victim} =
      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "How do I score?",
        answer: "Count the points.",
        visibility: "community",
        pooled: true
      })

    conn = login(conn, attacker)

    # Open the community thread so the row is genuinely in the attacker's
    # conversation — otherwise resubmit_question bails at `question == ""`
    # before ever reaching the ownership guard, and the test proves nothing.
    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(victim.id)}"
      )

    assert html =~ "How do I score?", "thread must be loaded for the exploit path to be reachable"

    render_click(view, "regenerate_answer", %{"id" => to_string(victim.id)})

    assert Repo.get(QuestionLog, victim.id), "another user's answer must survive"
    assert Repo.get!(QuestionLog, victim.id).answer == "Count the points."
  end

  test "an author regenerating their own community answer forks instead of deleting it",
       %{conn: conn} do
    author = create_user("regen_owner")
    game = published_game_fixture(%{name: "Regen Fork Game"})

    {:ok, promoted} =
      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "How do I score?",
        answer: "Count the points.",
        visibility: "community",
        pooled: true
      })

    conn = login(conn, author)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(promoted.id)}"
      )

    assert html =~ "How do I score?"

    render_click(view, "regenerate_answer", %{"id" => to_string(promoted.id)})

    # Promoted content is shared the moment it is promoted — even its author
    # must not delete it out from under other viewers.
    assert Repo.get(QuestionLog, promoted.id)
  end

  test "a forged community_vote from another game's id is ignored", %{conn: conn} do
    voter = create_user("vote_forger")
    game = published_game_fixture(%{name: "Vote Home Game"})
    other_game = published_game_fixture(%{name: "Vote Other Game", bgg_id: 987})

    {:ok, foreign} =
      Games.log_question(%{
        game_id: other_game.id,
        question: "Foreign question?",
        answer: "Foreign answer.",
        visibility: "community",
        pooled: true
      })

    conn = login(conn, voter)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "community_vote", %{"id" => to_string(foreign.id), "vote" => "up"})

    refute Games.get_user_community_vote(foreign.id, voter.id),
           "a row from another game must not be votable from this game's page"
  end
end
