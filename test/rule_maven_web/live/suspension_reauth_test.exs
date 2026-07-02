defmodule RuleMavenWeb.SuspensionReauthTest do
  @moduledoc """
  `on_mount(:default, ...)` only checked suspension at connect time. Once a
  socket is open, it outlives that check — an admin suspending a user
  mid-session left their live socket free to keep firing events. This mirrors
  the `:admin` live_session's per-event `reauth_event` hook (see
  `RuleMavenWeb.UserLiveAuth.reauth_event/3`) but for the `:default` session:
  the next event on an already-open socket must halt/redirect once the user
  is suspended, even though `current_user` in the socket assigns is a stale
  mount-time snapshot.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "suspending a user mid-session halts their next event on an open :default socket", %{
    conn: conn
  } do
    {:ok, user} =
      Users.create_user(%{
        username: "susp_live_user",
        email: "susp_live_user@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "Suspension Test Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # Suspend after mount — the open socket still has the pre-suspension user
    # in its assigns, mirroring the admin reauth hook's threat model.
    {:ok, _} = Users.suspend_user(user)

    result = render_click(view, "toggle_sidebar", %{})

    assert {:error, {:redirect, %{to: _}}} = result
    refute Process.alive?(view.pid)
  end
end
