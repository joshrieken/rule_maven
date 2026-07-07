defmodule RuleMavenWeb.GameLiveStreamingTest do
  @moduledoc """
  Ask-latency UX: (1) `{:ask_partial, …}` broadcasts render the streamed
  answer text in place of the loader while the ask is still pending; (2) a
  persona answer whose restyle is deferred (no styled fields on
  `:ask_complete`) renders the PLAIN answer immediately with a slim
  "voicing" badge — instead of holding the answer behind the full loader —
  and swaps the persona text in on `{:voice_ready, …}`.
  """

  use RuleMavenWeb.ConnCase, async: true
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

  defp ask_complete_payload(ql) do
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
    }
  end

  test "a pending ask renders streamed partial text instead of the loader", %{conn: conn} do
    user = setup_user("stream_partial")
    game = published_game_fixture(%{name: "Stream Partial Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html =
      view
      |> form("#ask-form", question: "How is the first player picked?")
      |> render_submit()

    # Before any tokens arrive: the loader.
    assert html =~ "voice-loader"

    ql =
      RuleMaven.Repo.one!(
        from(q in Games.QuestionLog,
          where: q.game_id == ^game.id,
          order_by: [desc: q.id],
          limit: 1
        )
      )

    send(view.pid, {:ask_partial, %{question_log_id: ql.id, text: "Roll the d20 to"}})

    html = render(view)
    assert html =~ "Roll the d20 to"
    assert html =~ "stream-cursor"
    refute html =~ "voice-loader-#{ql.id}"

    # The full answer landing clears the partial.
    {:ok, ql} = Games.log_question_update(ql, %{answer: "Roll the d20 to pick first player."})
    send(view.pid, {:ask_complete, ask_complete_payload(ql)})

    html = render(view)
    assert html =~ "Roll the d20 to pick first player."
    refute html =~ "stream-cursor"
  end

  test "deferred persona restyle shows the plain answer with a voicing badge, then swaps", %{
    conn: conn
  } do
    user = setup_user("stream_voice")
    game = published_game_fixture(%{name: "Stream Voice Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "Thinking...",
        visibility: "private"
      })

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_hook(view, "default_voice_restore", %{"voice" => "pirate"})

    {:ok, ql} = Games.log_question_update(ql, %{answer: "You roll 3 dice."})

    # AskWorker no longer restyles inline — the broadcast carries no styled
    # fields and the LiveView enqueues the on-demand VoiceWorker itself.
    send(view.pid, {:ask_complete, ask_complete_payload(ql)})

    html = render(view)
    assert html =~ "You roll 3 dice."
    assert html =~ "voice-badge"
    refute html =~ "voice-loader-#{ql.id}"
    assert_enqueued worker: RuleMaven.Workers.VoiceWorker, args: %{question_log_id: ql.id}

    send(view.pid, {:voice_ready, ql.id, "pirate", "Arr, three dice, matey."})

    html = render(view)
    assert html =~ "Arr, three dice, matey."
    refute html =~ "voice-badge"
  end
end
