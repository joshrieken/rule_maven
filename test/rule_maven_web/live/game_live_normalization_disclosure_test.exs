defmodule RuleMavenWeb.GameLiveNormalizationDisclosureTest do
  @moduledoc """
  When we rewrite (normalize) an asker's raw question, they have to be able to
  tell. The two-pane redesign moved that disclosure out of the message pane: the
  question lives once in the fixed `.qa-question` bar, which carries an italic
  `edited` chip, and tapping the bar opens an overlay pairing "You asked" (raw)
  with "We searched" (cleaned). Both are cheap to render and never reflow the
  answer, which is why the old inline "You asked:" subline is gone.

  The disclosure only renders for the asker (own questions) and admins — the
  main-chat query already scopes non-admins to their own rows. It stays hidden
  when raw and normalized match after case/whitespace folding.
  """

  use RuleMavenWeb.ConnCase, async: true
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

  # The overlay is the only place the raw wording is spelled out, so every
  # assertion about it has to go through the bar's tap target first.
  defp open_question_overlay(view) do
    view |> element(".qa-question__text") |> render_click()
  end

  test "shows original wording when the question was normalized", %{conn: conn} do
    user = setup_user("norm_show")
    game = published_game_fixture(%{name: "Norm Show Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "how many cards do i draw",
        cleaned_question: "How many cards does a player draw per turn?",
        answer: "You draw two cards.",
        promoted: false
      })

    conn = login(conn, user)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    # The bar carries the normalized wording plus the chip that advertises the
    # rewrite. The raw wording is deliberately NOT in the initial payload.
    assert html =~ "How many cards does a player draw per turn?"
    assert html =~ "qa-question__edited"
    refute html =~ "how many cards do i draw"

    html = open_question_overlay(view)

    assert html =~ "qa-overlay"
    assert html =~ "You asked"
    assert html =~ "how many cards do i draw"
    assert html =~ "We searched"
    assert html =~ "How many cards does a player draw per turn?"
  end

  test "discloses the just-typed wording when a re-ask is redirected to an existing thread",
       %{conn: conn} do
    user = setup_user("norm_redir")
    game = published_game_fixture(%{name: "Norm Redir Game"})

    # The thread the paraphrased re-ask gets deduped onto. Its own stored raw
    # equals its normalized form, so without the re-ask override no disclosure
    # would show at all.
    {:ok, source} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How are walls placed?",
        cleaned_question: "How are walls placed?",
        answer: "Walls go between two spaces.",
        promoted: false
      })

    # A second answered row so its id is present in the user's threads — the
    # redirect handler only acts when the provisional id is one of theirs.
    {:ok, prov} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Unrelated placeholder question?",
        answer: "Placeholder.",
        promoted: false
      })

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    send(
      view.pid,
      {:ask_redirect,
       %{
         question_log_id: prov.id,
         source_question_log_id: source.id,
         asked_as: "can walls block movement how do i place them"
       }}
    )

    # The row's own stored raw would say "not edited"; the `reask_typed` stash is
    # what makes the chip appear, so the chip is proof the stash survived.
    html = render(view)
    assert html =~ "How are walls placed?"
    assert html =~ "qa-question__edited"

    html = open_question_overlay(view)

    assert html =~ "You asked"
    assert html =~ "can walls block movement how do i place them"
    assert html =~ "We searched"
    assert html =~ "How are walls placed?"
  end

  test "hides the disclosure when raw and normalized match apart from case/space", %{conn: conn} do
    user = setup_user("norm_same")
    game = published_game_fixture(%{name: "Norm Same Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards does a player draw?",
        cleaned_question: "how many cards does a player draw?",
        answer: "You draw two cards.",
        promoted: false
      })

    conn = login(conn, user)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    refute html =~ "qa-question__edited"

    # Nothing to disclose, so even the opened overlay stays a plain restatement.
    html = open_question_overlay(view)

    refute html =~ "You asked"
    refute html =~ "We searched"
  end
end
