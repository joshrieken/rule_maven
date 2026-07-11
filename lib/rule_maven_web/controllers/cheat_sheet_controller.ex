defmodule RuleMavenWeb.CheatSheetController do
  use RuleMavenWeb, :controller

  alias RuleMaven.{Games, CheatSheet}

  # Cheatsheets are AI-derived summaries of copyrighted rules, so they're gated
  # to logged-in users (lighter than the admin-only rulebook HTML, but not open
  # to anonymous scraping).
  plug :require_login

  def show(conn, %{"id" => id}) do
    case Games.get_game_by_token(id) do
      nil -> not_found(conn)
      game -> serve_active_cheatsheet(conn, game)
    end
  end

  def show_version(conn, %{"id" => id, "version_id" => version_id}) do
    with game when not is_nil(game) <- Games.get_game_by_token(id),
         {:ok, vid} <- RuleMaven.Hashid.decode(version_id),
         version when not is_nil(version) <- CheatSheet.get_version_for_game(game, vid) do
      serve_content(conn, game.name, version.content)
    else
      _ -> not_found(conn)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("Not found")

  defp require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please log in to view cheatsheets.")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp serve_active_cheatsheet(conn, game) do
    docs = Games.list_documents(game)

    content =
      Enum.find_value(docs, fn doc ->
        active = CheatSheet.active_version(doc.id)

        if active,
          do: serve_content(conn, game.name, active.content <> delta_markdown(conn, game))
      end)

    if content do
      content
    else
      conn
      |> put_flash(:error, "No cheatsheet yet. Generate one from the Edit page.")
      |> redirect(to: ~p"/games/#{game}")
    end
  end

  # Appends a "what changes" section per expansion the viewer plays with (their
  # persisted selection; base-only or no deltas → empty string). Versioned
  # cheat sheets (show_version) stay pristine — deltas only decorate the
  # active sheet.
  defp delta_markdown(conn, game) do
    user = conn.assigns[:current_user]
    selected = if user, do: Games.effective_expansion_ids(user.id, game), else: []

    if selected == [] do
      ""
    else
      by_id = game |> Games.expansions_with_documents() |> Map.new(&{&1.id, &1})

      sections =
        selected
        |> Enum.flat_map(fn id ->
          with %{} = exp <- by_id[id],
               %{"rules" => rules, "setup" => setup} when rules != [] or setup != [] <-
                 RuleMaven.ExpansionDelta.stored(id) do
            bullets =
              Enum.map(rules, &"- #{&1}") ++
                Enum.map(setup, fn s ->
                  detail = if s["detail"] in [nil, ""], do: "", else: " — #{s["detail"]}"
                  "- *Setup:* #{s["title"]}#{detail}"
                end)

            ["\n\n---\n\n## What #{exp.name} changes\n\n" <> Enum.join(bullets, "\n")]
          else
            _ -> []
          end
        end)

      Enum.join(sections)
    end
  end

  defp serve_content(conn, game_name, markdown) do
    {:ok, html} = CheatSheet.wrap_html_for_serve(game_name, markdown)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
