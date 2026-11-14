defmodule RuleMavenWeb.GameSymbolsToolTest do
  @moduledoc "Symbols table tool, the gated icon route, and both icon switches."
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Hashid, Symbols, Users}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

  defp user(prefix, role \\ "user") do
    {:ok, u} =
      Users.create_user(%{
        username: "#{prefix}_u",
        email: "#{prefix}_u@test.com",
        password: "password1234",
        role: role
      })

    u
  end

  defp login(conn, u), do: Plug.Test.init_test_session(conn, %{"user_id" => u.id})

  setup %{conn: conn} do
    base = published_game_fixture(%{name: "Nida", bgg_id: 9301})
    exp = published_game_fixture(%{name: "Nida – Thing", bgg_id: 9302})
    Games.link_expansion(exp.id, base.id)

    {:ok, rel} = Symbols.store_image(base.id, @png, "hammer")

    {:ok, [hammer]} =
      Symbols.replace(base.id, [
        %{
          token: "[purple hammer symbol]",
          name: "Blacksmith",
          meaning: "Blacksmith class.",
          page: 7,
          image_path: rel
        }
      ])

    {:ok, _} = Symbols.replace(exp.id, [%{token: "[green horn symbol]", name: "Hunter"}])

    on_exit(fn ->
      Symbols.clear(base.id)
      Symbols.clear(exp.id)
    end)

    u = user("sym")
    %{conn: login(conn, u), base: base, exp: exp, hammer: hammer}
  end

  test "the tool lists the key with its icon, and adds expansion symbols when toggled on", %{
    conn: conn,
    base: base,
    exp: exp,
    hammer: hammer
  } do
    {:ok, view, _} = live(conn, ~p"/games/#{base}")
    html = render_click(view, "open_tool", %{"tool" => "symbols"})

    assert html =~ "Blacksmith"
    assert html =~ "Blacksmith class."
    assert html =~ ~p"/symbols/#{Hashid.encode(hammer.id)}/image"
    refute html =~ "Hunter"

    render_click(view, "toggle_expansion", %{"id" => to_string(exp.id)})
    html = render(view)
    assert html =~ "Hunter"
    assert html =~ "Thing"
  end

  test "icon route serves the image only while both switches allow it", %{
    conn: conn,
    base: base,
    hammer: hammer
  } do
    path = ~p"/symbols/#{Hashid.encode(hammer.id)}/image"

    resp = get(conn, path)
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "image/png"

    Symbols.set_images(base.id, false, nil)
    assert get(build_conn(), path).status == 404
    Symbols.set_images(base.id, true, nil)

    RuleMaven.Flags.disable(:symbol_images)
    on_exit(fn -> RuleMaven.Flags.enable(:symbol_images) end)
    assert get(build_conn(), path).status == 404
  end

  test "icon route hides a non-Ready game's icons from non-admins", %{base: base, hammer: hammer} do
    Games.Game
    |> RuleMaven.Repo.get!(base.id)
    |> Ecto.Changeset.change(playable: false)
    |> RuleMaven.Repo.update!()

    path = ~p"/symbols/#{Hashid.encode(hammer.id)}/image"

    assert get(build_conn(), path).status == 404
    assert build_conn() |> login(user("symadm", "admin")) |> get(path) |> Map.get(:status) == 200
    assert get(build_conn(), ~p"/symbols/zzzzzzzz/image").status == 404
  end

  test "with icons off the tool still shows the text key", %{conn: conn, base: base} do
    Symbols.set_images(base.id, false, nil)
    {:ok, view, _} = live(conn, ~p"/games/#{base}")
    html = render_click(view, "open_tool", %{"tool" => "symbols"})

    assert html =~ "Blacksmith"
    refute html =~ "/image\""
  end

  test "answers render known tokens as the book's icon + name", %{
    conn: conn,
    base: base,
    hammer: hammer
  } do
    {:ok, q} =
      Games.log_question(%{
        game_id: base.id,
        question: "What does the hammer do?",
        cleaned_question: "What does the hammer do?",
        answer: "Each [purple hammer symbol] lets you forge.",
        promoted: true,
        verified: true,
        browsable: true
      })

    {:ok, view, _} = live(conn, ~p"/games/#{base}/community")
    html = render_click(view, "toggle_expand", %{"id" => to_string(q.id)})

    assert html =~ ~p"/symbols/#{Hashid.encode(hammer.id)}/image"
    assert html =~ ~s(<span class="sym-label">Blacksmith</span>)
    # (The copy/share data-attributes keep the plain-text token.)
    assert html =~ ~s(Each <span class="sym-mark")
  end
end
