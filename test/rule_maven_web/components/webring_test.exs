defmodule RuleMavenWeb.WebringTest do
  @moduledoc "The Calzone Zone Ring at the foot of every page (root layout, Layouts.webring/1)."
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  @ring ~s(<nav class="webring" aria-label="Calzone Zone Ring">)

  defp assert_ring(html) do
    assert html =~ @ring
    # Rule Maven sits between the hub and Stir & Fold.
    assert html =~ ~s(href="https://lowcalcalzonezone.com")
    assert html =~ ~s(href="https://stirandfold.com")
    assert html =~ "Previous site in the Calzone Zone Ring: Low-Cal Calzone Zone"
    assert html =~ "Next site in the Calzone Zone Ring: Stir &amp; Fold"
  end

  test "a public page (/login) carries the ring", %{conn: conn} do
    conn |> get(~p"/login") |> html_response(200) |> assert_ring()
  end

  test "a signed-in page (/) carries the ring", %{conn: conn} do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "ring_member",
        email: "ring_member@test.com",
        password: "testpassword123",
        role: "user"
      })

    seen = Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.to_iso8601(DateTime.utc_now())})
    user = user |> Ecto.Changeset.change(tours_seen: seen) |> RuleMaven.Repo.update!()

    conn
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
    |> get(~p"/")
    |> html_response(200)
    |> assert_ring()
  end

  test "the 🥟 goes to the random site, and the names are there to reveal" do
    links = Lccz.Webring.links("rulemaven", %{}, &List.last/1)
    html = render_component(&RuleMavenWeb.Layouts.webring/1, links: links)

    assert html =~ ~s(href="https://drawburn.lowcalcalzonezone.com")
    assert html =~ "Calzone Zone Ring · random"
    assert html =~ ~s(class="webring__name")
    refute html =~ "style="
  end
end
