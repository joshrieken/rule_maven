defmodule RuleMavenWeb.ChatSpoilerMarkersTest do
  @moduledoc """
  The Ask page's sidebar says whose rows are whose (📖 prepared / 👍 saved /
  🌐 community for rows the viewer did not ask), and an answer drawing on a
  spoiler source renders behind a warning + "Show answer" — the hidden text is
  absent from the DOM until revealed.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.{Document, QuestionVote}
  alias RuleMaven.Repo

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

  defp upvote(ql, user) do
    Repo.insert!(%QuestionVote{question_log_id: ql.id, user_id: user.id, value: "up"})
  end

  defp game_path(game), do: ~p"/games/#{RuleMaven.Hashid.encode(game.id)}"

  defp open_thread(conn, user, game, ql) do
    conn
    |> login(user)
    |> live("#{game_path(game)}?t=#{RuleMaven.Hashid.encode(ql.id)}")
  end

  defp spoiler_doc(game) do
    Repo.insert!(%Document{
      game_id: game.id,
      label: "FAQ — spoilers",
      kind: "faq",
      status: "published",
      spoiler: true
    })
  end

  defp spoiler_citations(doc) do
    [
      %{
        "quote" => "The Sunkeeper unlocks at scenario 12.",
        "page" => 1,
        "document_id" => doc.id,
        "source" => doc.label
      }
    ]
  end

  describe "spoiler answers" do
    test "hidden behind a warning until Show answer is clicked", %{conn: conn} do
      u = user("sp_hide")
      game = published_game_fixture(%{name: "Spoiler Hide Game"})
      doc = spoiler_doc(game)

      ql =
        log(game, %{
          user_id: u.id,
          question: "When does the sun class unlock?",
          answer: "SECRETSUNKEEPER unlocks after scenario twelve.",
          cited_passage: "The Sunkeeper unlocks at scenario 12.",
          citations: spoiler_citations(doc)
        })

      {:ok, view, html} = open_thread(conn, u, game, ql)

      assert html =~ "Spoiler — this answer draws on campaign content"
      refute html =~ "SECRETSUNKEEPER"
      refute html =~ "The Sunkeeper unlocks at scenario 12."
      # the asker's own question stays visible
      assert html =~ "When does the sun class unlock?"

      html = view |> element("button", "Show answer") |> render_click()
      assert html =~ "SECRETSUNKEEPER"
      assert html =~ "The Sunkeeper unlocks at scenario 12."
    end

    test "a non-spoiler answer renders normally", %{conn: conn} do
      u = user("sp_plain")
      game = published_game_fixture(%{name: "Spoiler Plain Game"})
      _doc = spoiler_doc(game)
      ql = log(game, %{user_id: u.id, answer: "PLAINANSWER roll two dice."})

      {:ok, _view, html} = open_thread(conn, u, game, ql)
      assert html =~ "PLAINANSWER"
      refute html =~ "Spoiler — this answer"
      refute html =~ "Show answer"
    end

    test "another player's spoiler row is masked in the sidebar", %{conn: conn} do
      viewer = user("sp_side_v")
      other = user("sp_side_o")
      game = published_game_fixture(%{name: "Spoiler Sidebar Game"})
      doc = spoiler_doc(game)

      ql =
        log(game, %{
          user_id: other.id,
          question: "Which item does MASKEDQ unlock?",
          pooled: true,
          browsable: true,
          citations: spoiler_citations(doc)
        })

      upvote(ql, viewer)

      {:ok, _view, html} = conn |> login(viewer) |> live(game_path(game))
      assert html =~ "⚠️ Spoiler question"
      refute html =~ "MASKEDQ"
    end
  end

  describe "sidebar honesty" do
    test "Community picks header and markers on rows the viewer did not ask", %{conn: conn} do
      viewer = user("mk_v")
      other = user("mk_o")
      game = published_game_fixture(%{name: "Marker Game"})

      log(game, %{user_id: viewer.id, question: "My own question about ports?"})

      saved =
        log(game, %{
          user_id: other.id,
          question: "Upvoted question about robbers?",
          pooled: true,
          browsable: true
        })

      prepared =
        log(game, %{
          user_id: other.id,
          question: "Prepared question about trading?",
          llm_provider: "manual",
          pooled: true,
          browsable: true
        })

      upvote(saved, viewer)
      upvote(prepared, viewer)

      log(game, %{
        user_id: other.id,
        question: "Promoted question about roads?",
        promoted: true,
        pooled: true,
        browsable: true
      })

      {:ok, _view, html} = conn |> login(viewer) |> live(game_path(game))

      assert html =~ "Community picks"
      assert html =~ "👍 saved"
      assert html =~ "📖 prepared"
      # own row carries no marker: exactly one of each
      assert length(String.split(html, "👍 saved")) == 2
      assert length(String.split(html, "📖 prepared")) == 2
    end

    test "disclaimer says Rules Q&A", %{conn: conn} do
      u = user("mk_disc")
      game = published_game_fixture(%{name: "Disclaimer Game"})
      ql = log(game, %{user_id: u.id})
      {:ok, _view, html} = open_thread(conn, u, game, ql)
      assert html =~ "may be shared anonymously in the Rules Q&amp;A"
      refute html =~ "Community Q&amp;A"
    end
  end
end
