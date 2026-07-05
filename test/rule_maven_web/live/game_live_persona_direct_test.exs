defmodule RuleMavenWeb.GameLivePersonaDirectTest do
  @moduledoc """
  A fresh ask with a persona active should populate `voice_cache` directly off
  the `:ask_complete` broadcast (Task 5's `styled_voice`/`styled_answer`
  fields), so `apply_default_voice/2` sees the voice already cached and never
  enqueues a redundant VoiceWorker restyle job for it.
  """

  use RuleMavenWeb.ConnCase, async: true
  use Oban.Testing, repo: RuleMaven.Repo
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

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

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but the LiveView's `apply_default_voice/2` calls `Oban.insert/1` (via
  # VoiceWorker), which needs a named, configured instance to insert against.
  # Start a queueless/pluginless one under the default name so the plain
  # (unnamed) insert calls resolve for real, matching the established pattern
  # in test/rule_maven/workers/theme_palette_worker_test.exs.
  setup do
    start_supervised!({Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false})
    :ok
  end

  test "ask_complete with a styled_answer populates voice_cache without a VoiceWorker job", %{
    conn: conn
  } do
    user = setup_user("persona_direct")
    game = published_game_fixture(%{name: "Persona Direct Game"})

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

    # Set the active persona while the question is still pending. Mount
    # auto-selects this thread as active (it's the user's only question), so
    # if it already carried a final answer at this point, this same
    # `default_voice_restore` hook would fire `apply_default_voice/2` against
    # it immediately and enqueue a VoiceWorker job of its own —
    # `apply_default_voice/2`'s pending-answer filter
    # (`!&1[:pending] && &1[:content] != "Thinking..."`) is what protects us
    # here. Only after this do we land the real answer in the DB, mirroring
    # what happens for real once the ask job resolves.
    render_hook(view, "default_voice_restore", %{"voice" => "pirate"})

    {:ok, ql} = Games.log_question_update(ql, %{answer: "You roll 3 dice."})

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
         styled_answer: "Arr, roll three dice, ye scallywag."
       }}
    )

    html = render(view)
    assert html =~ "Arr, roll three dice"
    refute_enqueued worker: RuleMaven.Workers.VoiceWorker, args: %{question_log_id: ql.id}
  end
end
