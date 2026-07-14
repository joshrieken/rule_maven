defmodule RuleMavenWeb.GameLivePersonaAnswerAnimTest do
  @moduledoc """
  The answer text node is keyed by the active voice so LiveView replaces it
  (rather than patching it in place) whenever the persona changes — that
  replacement is what replays the `.answer-in` rise animation instead of the
  restyled text popping in.

  Streaming is the exception: the streamed partial and the final answer share
  the id for an unchanged voice, so the node survives the stream → final swap
  and never re-animates over text the stream already revealed.
  """

  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import Ecto.Query

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp setup_user(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  test "the answer node is keyed by voice, and question/answer ids never collide", %{conn: conn} do
    user = setup_user("anim_key")
    game = published_game_fixture(%{name: "Anim Key Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        visibility: "private"
      })

    conn = login(conn, user)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    # Only the assistant row carries an answer node. The two-pane redesign pinned
    # the question in the fixed `.qa-question` bar, so the user row no longer
    # emits an `ans-user-…` node at all — the role prefix now guards against a
    # collision that can only come from a future second answer-bearing role.
    assert html =~ ~s(id="ans-assistant-#{ql.id}-neutral")
    refute html =~ ~s(id="ans-user-#{ql.id})

    # Pick the persona, then land its restyle: the answer node's id changes, so
    # LiveView swaps the node and the rise animation replays.
    render_hook(view, "default_voice_restore", %{"voice" => "pirate"})
    send(view.pid, {:voice_ready, ql.id, "pirate", "Arr, roll three dice."})

    html = render(view)
    assert html =~ ~s(id="ans-assistant-#{ql.id}-pirate")
    refute html =~ ~s(id="ans-assistant-#{ql.id}-neutral")
    refute html =~ ~s(id="ans-user-#{ql.id})
  end

  test "a streamed persona answer keeps one node across the stream → final swap", %{conn: conn} do
    user = setup_user("anim_stream")
    game = published_game_fixture(%{name: "Anim Stream Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_hook(view, "default_voice_restore", %{"voice" => "pirate"})

    view
    |> form("#ask-form", question: "How is the first player picked?")
    |> render_submit()

    ql =
      RuleMaven.Repo.one!(
        from(q in Games.QuestionLog,
          where: q.game_id == ^game.id,
          order_by: [desc: q.id],
          limit: 1
        )
      )

    send(
      view.pid,
      {:ask_partial,
       %{question_log_id: ql.id, text: "Roll the d20", styled_text: "Arr, roll ye d20"}}
    )

    html = render(view)
    assert html =~ "Arr, roll ye d20"
    assert html =~ ~s(id="ans-assistant-#{ql.id}-pirate")

    {:ok, ql} = Games.log_question_update(ql, %{answer: "Roll the d20."})

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
         styled_voice: "pirate",
         styled_answer: "Arr, roll ye d20, matey."
       }}
    )

    html = render(view)
    assert html =~ "Arr, roll ye d20, matey."

    # Same id as the streaming node above: unchanged voice means LiveView
    # patches the text in place and the rise animation does not replay.
    assert html =~ ~s(id="ans-assistant-#{ql.id}-pirate")
  end
end
