defmodule RuleMavenWeb.GameExpansionComposerTest do
  @moduledoc """
  With an expansion toggled on, the Q&A composer says so (chip + placeholder)
  and the expansion's own suggested questions lead the suggestions list.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Settings}

  setup %{conn: conn} do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "composer_user",
        email: "composer_user@test.com",
        password: "password1234"
      })

    base = published_game_fixture(%{name: "Wingspan", bgg_id: 9101})
    exp = published_game_fixture(%{name: "Wingspan – Oceania", bgg_id: 9102})
    Games.link_expansion(exp.id, base.id)

    Settings.put(
      "suggestions_#{base.id}",
      Jason.encode!([%{"category" => "Turns", "questions" => ["How many actions per turn?"]}])
    )

    Settings.put(
      "suggestions_#{exp.id}",
      Jason.encode!([%{"category" => "Nectar", "questions" => ["When does nectar score?"]}])
    )

    %{conn: Plug.Test.init_test_session(conn, %{"user_id" => user.id}), base: base, exp: exp}
  end

  test "base game only: no chip, plain placeholder, base suggestions", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, ~p"/games/#{base}")
    html = render(view)

    refute has_element?(view, ~s|[data-testid="composer-expansions"]|)
    assert html =~ ~s|placeholder="Ask a rules question…"|
    assert html =~ "How many actions per turn?"
    refute html =~ "When does nectar score?"
  end

  test "expansion on: chip + placeholder name it, its suggestions come first", %{
    conn: conn,
    base: base,
    exp: exp
  } do
    {:ok, view, _html} = live(conn, ~p"/games/#{base}")
    render_click(view, "toggle_expansion", %{"id" => to_string(exp.id)})
    html = render(view)

    assert view |> element(~s|[data-testid="composer-expansions"]|) |> render() =~ "+ Oceania"
    assert html =~ ~s|placeholder="Ask a rules question (with Oceania)…"|
    assert html =~ ~r/class="expansion-tag".*?Oceania/s

    {exp_at, _} = :binary.match(html, "When does nectar score?")
    {base_at, _} = :binary.match(html, "How many actions per turn?")
    assert exp_at < base_at
  end

  test "expansion_short_name strips the base prefix" do
    assert Games.expansion_short_name(%{name: "Flash Point: Fire Rescue – 2nd Story"}, %{
             name: "Flash Point: Fire Rescue"
           }) == "2nd Story"

    assert Games.expansion_short_name(%{name: "Oceania"}, %{name: "Wingspan"}) == "Oceania"
  end
end
