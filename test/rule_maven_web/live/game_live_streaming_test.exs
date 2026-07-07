defmodule RuleMavenWeb.GameLiveStreamingTest do
  @moduledoc """
  Ask-latency UX: (1) `{:ask_partial, …}` broadcasts render the streamed
  answer text in place of the loader while the ask is still pending — a
  persona viewer streams `styled_text` and never sees the plain answer; (2)
  a persona answer whose restyle is deferred (no styled fields on
  `:ask_complete`) keeps the voice loader up until `{:voice_ready, …}`
  swaps the persona text in.

  async: false is deliberate: the setup starts a globally named Oban, the
  persona-direct LiveView file does the same, and two async files colliding
  on that name was a recurring suite flake.
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

  test "persona viewer streams styled_answer partials and never sees the plain text", %{
    conn: conn
  } do
    user = setup_user("stream_styled")
    game = published_game_fixture(%{name: "Stream Styled Game"})

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

    # Plain text streaming but no styled text yet: keep the loader, hide the plain.
    send(view.pid, {:ask_partial, %{question_log_id: ql.id, text: "Roll the d20", styled_text: nil}})

    html = render(view)
    refute html =~ "Roll the d20"
    assert html =~ "voice-loader-#{ql.id}-pirate"

    # Styled text arriving streams in its place.
    send(
      view.pid,
      {:ask_partial,
       %{question_log_id: ql.id, text: "Roll the d20", styled_text: "Arr, roll ye d20"}}
    )

    html = render(view)
    assert html =~ "Arr, roll ye d20"
    assert html =~ "stream-cursor"
    refute html =~ "Roll the d20,"
    refute html =~ "voice-loader-#{ql.id}"
  end

  test "text_done swaps the stream cursor for the citations-pending indicator", %{conn: conn} do
    user = setup_user("stream_done")
    game = published_game_fixture(%{name: "Stream Done Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

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

    # Text still streaming: cursor, no indicator.
    send(
      view.pid,
      {:ask_partial, %{question_log_id: ql.id, text: "Roll the d20 to", text_done: false}}
    )

    html = render(view)
    assert html =~ "stream-cursor"
    refute html =~ "cite-pending"

    # Answer string closed on the wire: citations/verdict still in flight —
    # drop the cursor, show the pending indicator.
    send(
      view.pid,
      {:ask_partial,
       %{question_log_id: ql.id, text: "Roll the d20 to pick.", text_done: true}}
    )

    html = render(view)
    assert html =~ "Roll the d20 to pick."
    refute html =~ "stream-cursor"
    assert html =~ "cite-pending"
    assert html =~ "Gathering rulebook citations"

    # :ask_complete clears the indicator.
    {:ok, ql} = Games.log_question_update(ql, %{answer: "Roll the d20 to pick."})
    send(view.pid, {:ask_complete, ask_complete_payload(ql)})

    html = render(view)
    refute html =~ "cite-pending"
  end

  test "deferred persona restyle keeps the voice loader up (no plain flash), then swaps", %{
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
    # fields and the LiveView enqueues the on-demand VoiceWorker itself. The
    # plain answer stays hidden behind the voice loader until the persona
    # text is ready — a persona viewer never sees the plain text flash.
    send(view.pid, {:ask_complete, ask_complete_payload(ql)})

    html = render(view)
    # The copy button's data-clipboard-text still carries the canonical text
    # (invisible); the rendered answer body must not.
    refute html =~ "<p>You roll 3 dice."
    refute html =~ "voice-badge"
    assert html =~ "voice-loader-#{ql.id}-pirate"
    assert_enqueued worker: RuleMaven.Workers.VoiceWorker, args: %{question_log_id: ql.id}

    send(view.pid, {:voice_ready, ql.id, "pirate", "Arr, three dice, matey."})

    html = render(view)
    assert html =~ "Arr, three dice, matey."
    refute html =~ "voice-loader-#{ql.id}"
  end
end
