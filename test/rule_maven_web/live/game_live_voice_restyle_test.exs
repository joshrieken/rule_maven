defmodule RuleMavenWeb.GameLiveVoiceRestyleTest do
  @moduledoc """
  Picking a persona on an already-answered thread must swap the restyled text in
  live, when the VoiceWorker's `{:voice_ready, ...}` broadcast lands — no reload.
  """
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Repo
  alias RuleMaven.Voices.GameVoice

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp broadcast_voice_ready(game, ql, content) do
    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      "game:#{game.id}",
      {:voice_ready, ql.id, "g:elminster", content}
    )
  end

  setup do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "voice_user",
        email: "voice_user@test.com",
        password: "password1234"
      })

    game = published_game_fixture()

    Repo.insert!(%GameVoice{
      game_id: game.id,
      slug: "elminster",
      label: "Elminster",
      emoji: "🧙",
      style: "Speak as a rambling wizard.",
      loading_phrases: ["Consulting the tomes…"]
    })

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards do I draw?",
        answer: "Draw two cards.",
        visibility: "private"
      })

    %{user: user, game: game, ql: ql}
  end

  test "voice picked on an open thread: the broadcast swaps the answer in", %{
    conn: conn,
    user: user,
    game: game,
    ql: ql
  } do
    token = RuleMaven.Hashid.encode(ql.id)
    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}?t=#{token}")

    render_click(view, "set_default_voice", %{"voice" => "g:elminster"})
    assert render(view) =~ "voice-loader"

    broadcast_voice_ready(game, ql, "Ah, my boy, draw two cards.")

    html = render(view)
    assert html =~ "Ah, my boy, draw two cards."
    refute html =~ "voice-loader"
  end

  test "voice picked first, then an existing question clicked: the broadcast swaps in", %{
    conn: conn,
    user: user,
    game: game,
    ql: ql
  } do
    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}")

    render_click(view, "set_default_voice", %{"voice" => "g:elminster"})
    render_click(view, "switch_thread", %{"id" => to_string(ql.id)})

    assert render(view) =~ "voice-loader"

    broadcast_voice_ready(game, ql, "Ah, my boy, draw two cards.")

    html = render(view)
    assert html =~ "Ah, my boy, draw two cards."
    refute html =~ "voice-loader"
  end

  # `Phoenix.PubSub` is node-local. When a second BEAM shares the Oban queue (a
  # stray `mix phx.server`, a remote console, a worktree run), that node dequeues
  # the VoiceWorker job and broadcasts `:voice_ready` to its *own* subscribers —
  # this LiveView never hears it, and the restyle loader spins forever even
  # though the restyle is sitting in `answer_voices`. The poll is the backstop:
  # the DB is the only state both nodes share.
  test "restyle written by another node (no broadcast): the poll swaps it in", %{
    conn: conn,
    user: user,
    game: game,
    ql: ql
  } do
    token = RuleMaven.Hashid.encode(ql.id)
    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}?t=#{token}")

    render_click(view, "set_default_voice", %{"voice" => "g:elminster"})
    assert render(view) =~ "voice-loader"

    # The other node finishes the job: cache row lands, no broadcast reaches us.
    :ok = RuleMaven.Voices.store_direct(ql.id, "g:elminster", "Ah, my boy, draw two cards.")

    send(view.pid, {:voice_poll, ql.id, "g:elminster", 1})

    html = render(view)
    assert html =~ "Ah, my boy, draw two cards."
    refute html =~ "voice-loader"
  end

  test "restyle never lands: the poll gives up and falls back to the plain answer", %{
    conn: conn,
    user: user,
    game: game,
    ql: ql
  } do
    token = RuleMaven.Hashid.encode(ql.id)
    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}?t=#{token}")

    render_click(view, "set_default_voice", %{"voice" => "g:elminster"})
    assert render(view) =~ "voice-loader"

    # Final attempt with nothing cached: stop spinning, show the plain answer.
    send(view.pid, {:voice_poll, ql.id, "g:elminster", 999})

    html = render(view)
    refute html =~ "voice-loader"
    assert html =~ "Draw two cards."
  end
end
