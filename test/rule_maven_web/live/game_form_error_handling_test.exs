defmodule RuleMavenWeb.GameFormErrorHandlingTest do
  @moduledoc """
  form.ex must not swallow save/upload failures:

  - An invalid update submit stays on the form with the changeset errors
    surfaced (no navigate, no "Saved" flash, no ingest against unsaved state).
  - Failed PDF copies are counted and surfaced, not silently filtered out
    (the split helper is tested directly; stubbing File.cp would be too
    invasive).
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin_user(name) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  test "invalid game update stays on form with errors, no navigate", %{conn: conn} do
    user = admin_user("form_error_user")

    # image_url set so the edit form isn't gated behind the BGG-sync prompt.
    game = game_fixture(%{name: "Original Game", image_url: "http://example.com/box.jpg"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    # Submit with an empty name (fails validate_required).
    html =
      view
      |> element("form#game-form")
      |> render_submit(%{"game" => %{"name" => ""}})

    # No success flash, changeset error surfaced instead.
    refute html =~ "Game updated!"
    assert html =~ "can&#39;t be blank"

    # No navigation happened — the view is still alive on the edit page.
    assert render(view) =~ "can&#39;t be blank"

    # Game unchanged in the DB.
    assert RuleMaven.Games.get_game!(game.id).name == "Original Game"
  end

  test "split_upload_results counts failed copies instead of dropping them" do
    assert RuleMavenWeb.GameLive.Form.split_upload_results([
             {:ok, %{pdf_path: "a.pdf", label: "a"}},
             {:error, "b.pdf: could not save file (enospc)"},
             {:ok, %{pdf_path: "c.pdf", label: "c"}}
           ]) ==
             {[%{pdf_path: "a.pdf", label: "a"}, %{pdf_path: "c.pdf", label: "c"}],
              ["b.pdf: could not save file (enospc)"]}

    assert RuleMavenWeb.GameLive.Form.split_upload_results([
             {:error, "x.pdf: could not save file (eacces)"},
             {:error, "y.pdf: could not save file (eacces)"}
           ]) ==
             {[], ["x.pdf: could not save file (eacces)", "y.pdf: could not save file (eacces)"]}

    assert RuleMavenWeb.GameLive.Form.split_upload_results([]) == {[], []}
  end

  test "combine_error_messages combines existing and upload errors" do
    existing_error = "Couldn't save: name can't be blank"
    upload_errors = ["document.pdf: could not save file (enospc)"]

    combined =
      RuleMavenWeb.GameLive.Form.combine_error_messages(existing_error, upload_errors)

    # Both messages should be present, combined with space
    assert combined ==
             "Couldn't save: name can't be blank 1 upload(s) failed: document.pdf: could not save file (enospc)"
  end

  test "combine_error_messages handles nil existing error" do
    upload_errors = ["document.pdf: could not save file (enospc)"]

    combined = RuleMavenWeb.GameLive.Form.combine_error_messages(nil, upload_errors)

    # Only upload message when no existing error
    assert combined == "1 upload(s) failed: document.pdf: could not save file (enospc)"
  end
end
