defmodule RuleMavenWeb.GameFormMultiParentTest do
  @moduledoc """
  Review finding (Important) on Task 3 (BGG multi-parent linking): the parent
  picker's assigns (`parent_selected_id`/`parent_selected_name`/`extra_bases`)
  were only computed at mount. `select_parent`/`clear_parent` persisted via
  `Games.link_expansion/2`/`unlink_expansion/2` but overwrote those assigns
  from the event params instead of re-deriving them from the DB — so linking
  a second base clobbered the first base out of the UI (though it stayed
  linked in the DB), and `clear_parent` only ever unlinked whichever base was
  currently in `parent_selected_id`.

  Covers: linking game to base A, then selecting base B in the picker, then
  clearing — asserting both bases stay visible/linked appropriately at each
  step.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

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

  test "linking a second base keeps the first base visible and linked", %{conn: conn} do
    user = admin_user("multi_parent_user")

    # image_url set so the edit form isn't gated behind the BGG-sync prompt
    # (same convention as game_form_kind_test.exs).
    exp =
      game_fixture(%{
        name: "Expansion Game",
        bgg_id: System.unique_integer([:positive]),
        image_url: "http://example.com/box.jpg"
      })

    base_a = game_fixture(%{name: "Base A", bgg_id: System.unique_integer([:positive])})
    base_b = game_fixture(%{name: "Base B", bgg_id: System.unique_integer([:positive])})

    Games.link_expansion(exp.id, base_a.id)

    conn = login(conn, user)
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(exp.id)}/edit")

    assert html =~ "Base A"

    html = render_click(view, "select_parent", %{"id" => to_string(base_b.id), "name" => "Base B"})

    # Both bases should still be linked in the DB...
    assert Enum.sort(Games.base_ids_for(exp.id)) == Enum.sort([base_a.id, base_b.id])

    # ...and both should still be visible in the rendered picker UI.
    assert html =~ "Base A"
    assert html =~ "Base B"

    # Clearing the currently-selected base should leave the other base linked
    # and rendered, not wipe the picker to "no base".
    html = render_click(view, "clear_parent", %{})

    remaining_ids = Games.base_ids_for(exp.id)
    assert length(remaining_ids) == 1
    [remaining_id] = remaining_ids
    remaining_name = if remaining_id == base_a.id, do: "Base A", else: "Base B"

    assert html =~ remaining_name
    refute Games.base_ids_for(exp.id) == []
  end
end
