defmodule RuleMavenWeb.GameLivePersonaModalTest do
  @moduledoc """
  The persona picker modal: opening it from the composer sets the modal target,
  and picking a persona records a persona_event and closes the modal.
  """

  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Repo
  alias RuleMaven.Voices.PersonaEvent

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

  # apply_default_voice/2 inserts a VoiceWorker job via Oban.insert/1, which needs
  # a named instance to resolve against (Oban runs in :manual test mode).
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  test "open from composer, pick a persona → records event and closes", %{conn: conn} do
    user = setup_user("persona_modal")
    game = published_game_fixture(%{name: "Persona Modal Game"})
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute has_element?(lv, "#persona-modal")

    lv
    |> element("#persona-default-btn")
    |> render_click()

    assert has_element?(lv, "#persona-modal")

    lv
    |> element("#persona-modal button[phx-value-voice=neutral]")
    |> render_click()

    refute has_element?(lv, "#persona-modal")
    assert Repo.aggregate(PersonaEvent, :count) == 1
    assert [%PersonaEvent{voice_id: "neutral", game_id: gid, user_id: uid}] = Repo.all(PersonaEvent)
    assert gid == game.id
    assert uid == user.id
  end
end
