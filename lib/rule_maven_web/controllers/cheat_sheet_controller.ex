defmodule RuleMavenWeb.CheatSheetController do
  use RuleMavenWeb, :controller

  alias RuleMaven.{Games, CheatSheet}

  # Cheatsheets are AI-derived summaries of copyrighted rules, so they're gated
  # to logged-in users (lighter than the admin-only rulebook HTML, but not open
  # to anonymous scraping).
  plug :require_login

  def show(conn, %{"id" => id}) do
    game = Games.get_game!(id)
    serve_active_cheatsheet(conn, game)
  end

  def show_version(conn, %{"id" => id, "version_id" => version_id}) do
    game = Games.get_game!(id)
    version = CheatSheet.get_version!(version_id)
    serve_content(conn, game.name, version.content)
  end

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
        if active, do: serve_content(conn, game.name, active.content)
      end)

    if content do
      content
    else
      conn
      |> put_flash(:error, "No cheatsheet yet. Generate one from the Edit page.")
      |> redirect(to: ~p"/games/#{game.id}")
    end
  end

  defp serve_content(conn, game_name, markdown) do
    {:ok, html} = CheatSheet.wrap_html_for_serve(game_name, markdown)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
