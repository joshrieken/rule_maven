defmodule RuleMavenWeb.GameLiveCitationSourceTest do
  @moduledoc """
  The citation figcaption always labeled the excerpt "Rulebook", even after
  Task 8 added `cited_source` to QuestionLog rows so multi-source games could
  attribute an answer to its actual document (e.g. "Official FAQ"). This
  drives a real connected LiveView over conversation history and asserts the
  figcaption uses `cited_source` when present, falling back to "Rulebook"
  for pre-existing rows where it's nil.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  # The citation-readability restyle split the caption's single "<source> ·
  # p.<n>" string into two elements: the source label, and the page as a
  # styled `.cite-page` chip (the "·" is gone — the chip is the separator).
  # The property under test is unchanged — the caption names the cited source
  # and the page — so assert against the caption element itself rather than a
  # literal that only ever held while the two were one string. `element/2`
  # raises unless exactly one figcaption is rendered, so this still proves the
  # caption exists.
  defp figcaption(view), do: view |> element("figure figcaption") |> render()

  defp setup_user(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  test "figcaption shows the cited source label and page", %{conn: conn} do
    user = setup_user("cite_src")
    game = published_game_fixture(%{name: "Cite Src Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How does the FAQ handle ties?",
        answer: "Ties are broken by re-rolling.",
        cited_passage: "In case of a tie, re-roll all dice.",
        cited_page: 2,
        cited_source: "Official FAQ",
        visibility: "private"
      })

    conn = login(conn, user)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    caption = figcaption(view)
    assert caption =~ "Official FAQ"
    assert caption =~ "p.2"
  end

  test "figcaption falls back to Rulebook when cited_source is nil", %{conn: conn} do
    user = setup_user("cite_nil")
    game = published_game_fixture(%{name: "Cite Nil Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        cited_passage: "Each player rolls three dice per turn.",
        cited_page: 5,
        visibility: "private"
      })

    conn = login(conn, user)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    caption = figcaption(view)
    assert caption =~ "Rulebook"
    assert caption =~ "p.5"
  end

  test "same-page citations merge into one card, ellipsis-joined, and cards sort by page", %{
    conn: conn
  } do
    user = setup_user("cite_group")
    game = published_game_fixture(%{name: "Cite Group Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How is the d20 used?",
        answer: "It picks the first player and damages the Beholder.",
        citations: [
          %{
            "quote" => "Damage the Beholder's eyestalks.",
            "page" => 11,
            "source" => "Core rules"
          },
          %{
            "quote" => "Roll the d20 to determine the first player.",
            "page" => 5,
            "source" => "Core rules"
          },
          %{
            "quote" => "then blind its central antimagic eye.",
            "page" => 11,
            "source" => "Core rules"
          }
        ],
        visibility: "private"
      })

    conn = login(conn, user)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    # Same-page citations (p.11) are merged with ellipsis (apostrophe HTML-encoded as &#39;)
    assert html =~ "Damage the Beholder&#39;s eyestalks. … then blind its central antimagic eye."

    # Cards are sorted by page: p.5 appears before p.11
    [_before_p5, after_p5] =
      String.split(html, "Roll the d20 to determine the first player.", parts: 2)

    assert after_p5 =~ "Damage the Beholder"
  end
end
