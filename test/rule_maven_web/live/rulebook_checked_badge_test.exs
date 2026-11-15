defmodule RuleMavenWeb.RulebookCheckedBadgeTest do
  @moduledoc """
  Answers Claude imported or corrected outside the app (llm_provider "manual":
  every citation verified verbatim against the cited page) show a
  "Rulebook-checked" status — NOT admin-verified, and with no change to trust:
  they stay provisional, so one player flag still pulls a bad one. Pool copies
  served from such a row inherit the status via pool_source_id.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(prefix) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_u",
        email: "#{prefix}_u@test.com",
        password: "password1234"
      })

    u
  end

  defp log(game, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "How many dice do I roll?",
            answer: "Roll two dice.",
            cited_passage: "Roll two dice at the start of your turn.",
            cited_page: 4,
            citation_valid: true,
            promoted: false
          },
          attrs
        )
      )

    q
  end

  defp open_thread(conn, user, game, ql) do
    conn
    |> login(user)
    |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}")
  end

  describe "rulebook_checked? helpers" do
    test "QuestionLog: only the manual provider counts" do
      assert QuestionLog.rulebook_checked?(%QuestionLog{llm_provider: "manual"})
      refute QuestionLog.rulebook_checked?(%QuestionLog{llm_provider: "openrouter"})
      refute QuestionLog.rulebook_checked?(%QuestionLog{llm_provider: "pool"})
      refute QuestionLog.rulebook_checked?(%QuestionLog{})
    end

    test "Games: a pool copy inherits its source row's status" do
      game = published_game_fixture(%{name: "RBC Helper Game"})
      manual = log(game, %{llm_provider: "manual", pooled: true, browsable: true})
      model = log(game, %{llm_provider: "openrouter", question: "Other?", pooled: true})

      copy_of = fn src ->
        log(game, %{llm_provider: "pool", llm_model: "cached-unverified", pool_source_id: src.id})
      end

      assert Games.answer_rulebook_checked?(manual)
      assert Games.answer_rulebook_checked?(copy_of.(manual))
      refute Games.answer_rulebook_checked?(model)
      refute Games.answer_rulebook_checked?(copy_of.(model))
    end
  end

  describe "asker's thread" do
    test "a manual answer reads Rulebook-checked, not Admin-verified", %{conn: conn} do
      u = user("rbc_manual")
      game = published_game_fixture(%{name: "RBC Manual Game"})
      ql = log(game, %{user_id: u.id, llm_provider: "manual", llm_model: "claude-code"})

      {:ok, _view, html} = open_thread(conn, u, game, ql)
      assert html =~ "Rulebook-checked"
      refute html =~ "Admin-verified"
    end

    test "a pool copy of a manual answer says so instead of 'Unverified answer'", %{conn: conn} do
      u = user("rbc_pool")
      game = published_game_fixture(%{name: "RBC Pool Game"})
      src = log(game, %{llm_provider: "manual", pooled: true, browsable: true})

      ql =
        log(game, %{
          user_id: u.id,
          llm_provider: "pool",
          llm_model: "cached-unverified",
          pool_source_id: src.id
        })

      {:ok, _view, html} = open_thread(conn, u, game, ql)
      assert html =~ "Rulebook-checked"
      assert html =~ "📖 Rulebook-checked answer"
      refute html =~ "🔎 Unverified answer"
    end

    test "a live model answer keeps its citation level", %{conn: conn} do
      u = user("rbc_model")
      game = published_game_fixture(%{name: "RBC Model Game"})
      ql = log(game, %{user_id: u.id, llm_provider: "openrouter"})

      {:ok, _view, html} = open_thread(conn, u, game, ql)
      assert html =~ "Cited from rulebook"
      refute html =~ "Rulebook-checked"
    end
  end

  describe "community page" do
    test "manual rows carry a Rulebook-checked pill instead of Player-asked", %{conn: conn} do
      viewer = user("rbc_viewer")
      game = published_game_fixture(%{name: "RBC Community Game"})

      log(game, %{
        llm_provider: "manual",
        pooled: true,
        browsable: true,
        question: "Checked question about trading?",
        answer: "Trade checked."
      })

      log(game, %{
        llm_provider: "openrouter",
        pooled: true,
        browsable: true,
        question: "Model question about robbers?",
        answer: "Robber model."
      })

      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/games/#{game}/community")
      html = render_change(view, "search", %{"q" => "question about"})

      assert html =~ "📖 Rulebook-checked"
      assert html =~ "🧪 Player-asked"
      # exactly one of each: the manual row is not ALSO labelled player-asked
      assert length(String.split(html, "🧪 Player-asked")) == 2
    end
  end
end
