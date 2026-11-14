defmodule RuleMavenWeb.SymbolController do
  @moduledoc """
  Serves a symbol's cropped rulebook icon. Gated on every request: the icon
  switches (`Symbols.images_enabled?/1` — global kill switch AND per-game) and
  the game's visibility (Ready, or an admin). Every failure is a 404, so the
  route never confirms what exists.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.{Games, Hashid, Repo, Symbols, Uploads, Users}
  alias RuleMaven.Symbols.Symbol

  def image(conn, %{"id" => token}) do
    user = conn.assigns[:current_user]

    with {:ok, id} <- Hashid.decode(token),
         %Symbol{image_path: path, game_id: game_id} when is_binary(path) <- Repo.get(Symbol, id),
         true <- Symbols.images_enabled?(game_id),
         %{} = game <- Games.get_game(game_id),
         true <- game.playable or (user != nil and Users.can?(user, :admin)),
         full = Uploads.resolve(path),
         true <- File.regular?(full) do
      conn
      |> put_resp_content_type(Symbols.content_type(path))
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, full)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
