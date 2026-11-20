defmodule RuleMavenWeb.WebringTest do
  @moduledoc "The faint 🥟 into the Calzone Zone Ring at the foot of every page (root layout, Layouts.webring/1)."
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp assert_ring(html) do
    assert html =~
             ~s(<a href="#{Lccz.Webring.url()}" class="webring" aria-label="Calzone Zone Ring">🥟</a>)
  end

  test "a public page (/login) carries the 🥟", %{conn: conn} do
    conn |> get(~p"/login") |> html_response(200) |> assert_ring()
  end

  test "a signed-in page (/) carries the 🥟", %{conn: conn} do
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

  test "the 🥟 has no label to reveal and no inline style" do
    html = render_component(&RuleMavenWeb.Layouts.webring/1, %{})
    refute html =~ "Calzone Zone Ring · random"
    refute html =~ "style="
  end
end
