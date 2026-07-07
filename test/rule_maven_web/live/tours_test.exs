defmodule RuleMavenWeb.ToursTest do
  @moduledoc """
  Onboarding tours: auto-start on first visit, done/skip stamping, replay
  links in the user dropdown, and the /help guide + FAQ page.
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  import Ecto.Query

  alias RuleMaven.Games
  alias RuleMaven.Users
  alias RuleMavenWeb.Tours

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix) do
    {:ok, user} =
      Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  test "every tour has steps with title and body" do
    assert Enum.sort(Tours.ids()) == ["answer", "game", "games"]

    for id <- Tours.ids(), step <- Tours.steps(id) do
      assert is_binary(step.title) and step.title != ""
      assert is_binary(step.body) and step.body != ""
    end
  end

  # Auto-start is attribute-driven: the hook sees data-tour-autostart and
  # requests the tour via "tour_replay" (a mount-time push_event can be lost
  # on join retries, so the client pulls instead).
  test "games tour auto-starts on the games list for a fresh user", %{conn: conn} do
    user = create_user("fresh")
    {:ok, view, _html} = conn |> login(user) |> live(~p"/")

    assert render(view) =~ ~s(data-tour-autostart="games")

    render_hook(view, "tour_replay", %{"id" => "games"})
    assert_push_event(view, "tour:start", %{id: "games", steps: [_ | _]})
  end

  test "games tour does not auto-start once seen", %{conn: conn} do
    user = create_user("seen")
    {:ok, user} = Users.mark_tour_seen(user, "games")

    {:ok, view, _html} = conn |> login(user) |> live(~p"/")

    refute render(view) =~ "data-tour-autostart"
  end

  test "tour_done stamps the tour seen", %{conn: conn} do
    user = create_user("done")
    {:ok, view, _html} = conn |> login(user) |> live(~p"/")

    render_hook(view, "tour_done", %{"id" => "games"})

    assert Users.tour_seen?(Users.get_user(user.id), "games")
  end

  test "tour_done ignores unknown tour ids", %{conn: conn} do
    user = create_user("bogus")
    {:ok, view, _html} = conn |> login(user) |> live(~p"/")

    render_hook(view, "tour_done", %{"id" => "nope"})

    assert Users.get_user(user.id).tours_seen == %{}
  end

  test "tour_replay re-pushes a tour even when already seen", %{conn: conn} do
    user = create_user("replay")
    {:ok, user} = Users.mark_tour_seen(user, "games")
    {:ok, view, _html} = conn |> login(user) |> live(~p"/")

    render_hook(view, "tour_replay", %{"id" => "games"})

    assert_push_event(view, "tour:start", %{id: "games"})
  end

  test "user dropdown offers help and tour replays", %{conn: conn} do
    user = create_user("menu")
    html = conn |> login(user) |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/help")
    assert html =~ ~s(data-tour-replay="games")
    assert html =~ ~s(data-tour-replay="game")
    assert html =~ ~s(data-tour-replay="answer")
  end

  test "/help renders the guide and FAQ without login", %{conn: conn} do
    html = conn |> get(~p"/help") |> html_response(200)

    assert html =~ "Help &amp; Guide"
    assert html =~ "FAQ"
    assert html =~ "AI can still be wrong"
  end

  describe "answer tour" do
    setup do
      start_supervised!(
        {Oban,
         repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
      )

      :ok
    end

    defp complete_ask(view, game, answer) do
      view
      |> form("#ask-form", question: "How do turns work?")
      |> render_submit()

      ql =
        RuleMaven.Repo.one!(
          from(q in Games.QuestionLog,
            where: q.game_id == ^game.id,
            order_by: [desc: q.id],
            limit: 1
          )
        )

      {:ok, ql} = Games.log_question_update(ql, %{answer: answer})

      send(
        view.pid,
        {:ask_complete,
         %{
           question_log_id: ql.id,
           faq_hit: false,
           pool_hit: false,
           tier: nil,
           verified: false,
           source_question_log_id: nil,
           followups: [],
           also_asked: [],
           cited_page: nil,
           refused: false,
           verdict: "info",
           raw_response: nil,
           styled_voice: nil,
           styled_answer: nil
         }}
      )

      render(view)
    end

    test "auto-starts when the user's first answer lands", %{conn: conn} do
      user = create_user("anstour")
      game = published_game_fixture(%{name: "Answer Tour Game"})

      {:ok, view, _html} =
        conn |> login(user) |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

      complete_ask(view, game, "Play proceeds clockwise.")

      assert_push_event(view, "tour:start", %{id: "answer", steps: [_ | _]})
    end

    test "does not start again once seen", %{conn: conn} do
      user = create_user("anstour_seen")
      {:ok, user} = Users.mark_tour_seen(user, "answer")
      game = published_game_fixture(%{name: "Answer Tour Seen Game"})

      {:ok, view, _html} =
        conn |> login(user) |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

      complete_ask(view, game, "Play proceeds clockwise.")

      refute_push_event(view, "tour:start", %{id: "answer"})
    end
  end
end
