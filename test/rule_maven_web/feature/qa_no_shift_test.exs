defmodule RuleMavenWeb.Feature.QaNoShiftTest do
  use PhoenixTest.Playwright.Case,
    async: false,
    browser_context_opts: [viewport: %{width: 390, height: 844}]

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  390px no-shift guarantee: the fixed three-row Q&A frame (`.qa-chip` /
  `.answer-pane` / `.chat-input`) must keep the composer's on-screen position
  identical while asking, while "thinking", and once the answer resolves —
  only `.answer-pane` (row 2) may scroll. Also asserts a fresh answer lands
  pinned to the top of that scroll region.

  Drives a REAL ask end-to-end (fills the composer, clicks Send) rather than
  a pre-seeded thread, so it exercises the actual "Thinking..." → streamed →
  complete state machine the product guarantee is about. The LLM call itself
  is faked: `config/test.exs` sets `Oban testing: :manual`, so the LiveView's
  `Oban.insert(AskWorker.new(...))` lands a DB row but doesn't run — this
  test manually drains the `:ask` queue (same trick as
  `ask_worker_streaming_test.exs`) once it has captured the "thinking" DOM
  state, against a local fake OpenAI-compatible endpoint wired in via the
  `llm_proxy_url` setting.
  """

  alias RuleMaven.{Games, Repo}

  defmodule FakeLLM do
    import Plug.Conn

    # Long enough to overflow `.answer-pane` on a 390x844 viewport, so tests
    # can assert the pane scrolls independently of the fixed frame.
    @answer "**Yes** — you may stack a Draw 4 on a Draw 2.\n\n" <>
              String.duplicate("More rules text to force the answer pane to overflow. ", 80)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      if req["stream"] do
        sse(conn)
      else
        json = %{
          "choices" => [
            %{
              "message" => %{"content" => "Can I stack a Draw 4 on a Draw 2?"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(json))
      end
    end

    defp sse(conn) do
      answer = @answer

      full =
        Jason.encode!(%{
          answer: answer,
          verdict: "info",
          citations: [
            %{quote: "You may stack a Draw 4 on a Draw 2.", page: 3, source: "Core rules"}
          ],
          followups: [],
          also_asked: []
        })

      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)

      event = %{"choices" => [%{"delta" => %{"content" => full}, "finish_reason" => nil}]}
      {:ok, conn} = chunk(conn, "data: #{Jason.encode!(event)}\n\n")

      finish = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 900, "completion_tokens" => 120, "total_tokens" => 1020}
      }

      {:ok, conn} = chunk(conn, "data: #{Jason.encode!(finish)}\n\n")
      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  setup do
    # Oban isn't supervised in test (`config/test.exs` sets `testing:
    # :manual`, and `RuleMaven.Application` skips starting it entirely under
    # that setting — see `application.ex`). The "ask" handler still calls
    # `Oban.insert/1`, which needs a NAMED instance to exist even if nothing
    # ever runs it automatically — start one with no live queues/plugins
    # (same pattern as `game_live_ask_exactly_test.exs`), then drain the
    # `:ask` queue by hand once we've captured the "thinking" state.
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    game = RuleMaven.GamesFixtures.published_game_fixture(%{name: "NoShiftGame"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    Repo.insert!(%Games.Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: "[Page 3]\nYou may stack a Draw 4 on a Draw 2.",
      page_number: 1,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "no_shift_user_#{System.unique_integer([:positive])}",
        email: "no_shift_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    # Fresh users autostart onboarding tour; the spotlight overlay would sit
    # on top of the page and swallow the click we need to make.
    seen = Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})
    user |> Ecto.Changeset.change(tours_seen: seen) |> Repo.update!()

    {:ok, server} = Bandit.start_link(plug: FakeLLM, port: 0, ip: :loopback)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, _} = RuleMaven.Settings.put("llm_proxy_url", "http://127.0.0.1:#{port}")

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :embed_mock)
      Process.exit(server, :normal)
    end)

    %{game: game, user: user}
  end

  defp login(conn, user) do
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)
    visit(conn, "/auto-login?token=#{token}")
  end

  # Runs the JS geometry probe on the given element and blocks until the
  # browser reports back — `evaluate/4`'s callback fires in the driver
  # process, so hop it to `self()` the way `subbar_visual_test.exs` does.
  defp bounding_top(conn, selector) do
    parent = self()

    script = """
    () => {
      var el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) return null;
      return el.getBoundingClientRect().top;
    }
    """

    evaluate(conn, script, [is_function: true], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, v} -> v
    after
      5_000 -> flunk("bounding_top probe timed out")
    end
  end

  defp scroll_top(conn, selector) do
    parent = self()

    script = """
    () => {
      var el = document.querySelector(#{Jason.encode!(selector)});
      return el ? el.scrollTop : null;
    }
    """

    evaluate(conn, script, [is_function: true], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, v} -> v
    after
      5_000 -> flunk("scroll_top probe timed out")
    end
  end

  # `.chat-input` plays a one-time `qa-rise-in` entrance animation on every
  # connect (0.22s delay + 0.5s duration — see `.chat-layout .chat-input` in
  # app.css): its `getBoundingClientRect()` doesn't settle at the resting
  # position until that finishes. Sampling mid-animation is a test-timing
  # artifact, not a real shift, so wait for the browser to report the
  # animation done before taking any geometry baseline.
  defp await_entrance_animation(conn, selector) do
    parent = self()

    script = """
    (el) => {
      var node = document.querySelector(#{Jason.encode!(selector)});
      if (!node) return Promise.resolve(null);
      var anims = node.getAnimations ? node.getAnimations() : [];
      return Promise.all(anims.map(function(a) { return a.finished.catch(function() {}); })).then(function() { return true; });
    }
    """

    evaluate(conn, script, [is_function: true], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, _} -> :ok
    after
      5_000 -> flunk("await_entrance_animation probe timed out")
    end
  end

  test "composer does not move between thinking and complete, answer pane pins to top",
       %{conn: conn, game: game, user: user} do
    conn =
      conn
      |> login(user)
      |> visit("/games/#{RuleMaven.Hashid.encode(game.id)}")

    await_entrance_animation(conn, ".chat-input")
    top_before = bounding_top(conn, ".chat-input")

    # The composer's question field has no accessible <label> (bare
    # placeholder input), so PhoenixTest's label-matching fill_in can't find
    # it — drive it with the raw-selector `type/3` escape hatch instead.
    conn = type(conn, "#ask-input", "Can I stack a Draw 4 on a Draw 2?")

    conn = click_button(conn, "Send")

    # The "Thinking..." row is committed synchronously by the LiveView
    # handler (before the Oban job even runs), so it's already on screen.
    conn = assert_has(conn, ".verdict-stamp--pending")

    top_thinking = bounding_top(conn, ".chat-input")
    assert_in_delta top_before, top_thinking, 1.0

    # Now let the (faked) AskWorker actually run and broadcast the answer.
    Oban.drain_queue(queue: :ask, with_scheduled: true)

    conn = assert_has(conn, ".verdict-stamp:not(.verdict-stamp--pending)", timeout: 10_000)

    top_done = bounding_top(conn, ".chat-input")
    assert_in_delta top_before, top_done, 1.0

    assert scroll_top(conn, ".answer-pane") == 0
  end
end
