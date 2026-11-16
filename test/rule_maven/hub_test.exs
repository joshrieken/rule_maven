defmodule RuleMaven.HubTest do
  # hub_request?/1 reads global config (Application env): not async.
  use RuleMaven.DataCase, async: false

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Changelog, Hub, Repo, Users}
  alias RuleMaven.Games.QuestionLog

  @now ~U[2026-11-15 12:00:00Z]
  @day 86_400

  setup do
    {:ok, alice} =
      Users.create_user(%{username: "alice", email: "a@example.com", password: "correct horse 1"})

    {:ok, alice} = RuleMaven.Auth.SignOn.link_user(alice, "sub-alice")
    %{alice: alice, game: game_fixture(%{name: "Wingspan"})}
  end

  defp ask(user, game, days_ago, attrs \\ %{}) do
    at = DateTime.add(@now, -days_ago * @day, :second)

    Repo.insert!(
      struct(
        %QuestionLog{
          game_id: game.id,
          user_id: user.id,
          question: "Q?",
          answer: "A.",
          inserted_at: at,
          updated_at: at
        },
        attrs
      )
    )
  end

  describe "summary/2" do
    test "nil for someone who never signed in here, or a suspended account", %{alice: alice} do
      assert Hub.summary("sub-nobody", @now) == nil
      {:ok, _} = Users.suspend_user(alice)
      assert Hub.summary("sub-alice", @now) == nil
    end

    test "level 0, not active, a nudge, no detail before any question" do
      summary = Hub.summary("sub-alice", @now)

      assert %{level: 0, active: false, headline: "No questions yet. Pick a game and ask."} =
               summary

      refute Map.has_key?(summary, :detail)
      assert summary.version == Changelog.app_version()
      assert is_boolean(summary.updated)
    end

    test "counts this week, names the last game, and grows with questions asked", %{
      alice: alice,
      game: game
    } do
      other = game_fixture(%{name: "Root", bgg_id: 7})
      ask(alice, other, 20)
      ask(alice, game, 2)

      assert %{
               level: 1,
               active: true,
               headline: "1 question this week",
               detail: "Last game: Wingspan"
             } =
               Hub.summary("sub-alice", @now)

      [_, second | _] = Hub.levels()
      for _ <- 3..second, do: ask(alice, other, 30)
      assert %{level: 2, headline: "1 question this week"} = Hub.summary("sub-alice", @now)

      ask(alice, game, 1)
      assert Hub.summary("sub-alice", @now).headline == "2 questions this week"
    end

    test "says how long ago when nothing happened this week", %{alice: alice, game: game} do
      ask(alice, game, 9)

      assert %{active: false, headline: "Last question 9 days ago", level: 1} =
               Hub.summary("sub-alice", @now)
    end

    test "imported prepared answers and failed asks don't count", %{alice: alice, game: game} do
      ask(alice, game, 1, %{llm_provider: "manual"})
      ask(alice, game, 1, %{error_kind: "timeout"})
      assert %{level: 0, active: false} = Hub.summary("sub-alice", @now)
    end

    test "keeps the headline and detail short", %{alice: alice} do
      long = game_fixture(%{name: String.duplicate("Very Long Game Name ", 10), bgg_id: 9})
      ask(alice, long, 1)
      summary = Hub.summary("sub-alice", @now)
      assert String.length(summary.detail) == Hub.detail_max()
      assert String.ends_with?(summary.detail, "…")
      assert String.length(summary.headline) <= Hub.headline_max()
    end

    test "updated: release notes this person hasn't opened", %{alice: alice} do
      if Changelog.visible_releases(false) != [] do
        assert Hub.summary("sub-alice", @now).updated
        {:ok, _} = Changelog.mark_seen(alice)
        refute Hub.summary("sub-alice", @now).updated
      end
    end
  end

  describe "hub_request?/1" do
    setup do
      on_exit(fn -> Application.delete_env(:rule_maven, :hub_secret) end)
    end

    test "needs the configured secret, exactly" do
      Application.delete_env(:rule_maven, :hub_secret)
      refute Hub.hub_request?("Bearer anything")

      Application.put_env(:rule_maven, :hub_secret, "")
      refute Hub.hub_request?("Bearer ")

      Application.put_env(:rule_maven, :hub_secret, "s3cret-s3cret")
      assert Hub.hub_request?("Bearer s3cret-s3cret")
      assert Hub.hub_request?("bearer s3cret-s3cret")
      refute Hub.hub_request?("Bearer s3cret")
      refute Hub.hub_request?("s3cret-s3cret")
      refute Hub.hub_request?("Bearer s3cret-s3cret extra")
      refute Hub.hub_request?(nil)
    end
  end
end
