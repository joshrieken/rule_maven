defmodule RuleMavenWeb.RulebookController do
  @moduledoc """
  Serves the extracted-text HTML view and the original PDF of a rulebook to admins only.

  Rulebooks may be copyrighted, so the original PDF is never served over HTTP
  (the `uploads` dir is no longer in `static_paths`), and the extracted-text
  HTML is gated to admins. Regular users only ever see a source's name.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.{Games, Users}

  def html(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with true <- user && Users.can?(user, :admin),
         {:ok, doc_id} <- RuleMaven.Hashid.decode(id),
         %Games.Document{html_path: html_path} when is_binary(html_path) <-
           Games.get_document(doc_id),
         full_path = RuleMaven.Uploads.resolve(html_path),
         true <- File.exists?(full_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, full_path)
    else
      # 404 (not 403) so the route doesn't reveal which documents exist to
      # non-admins.
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  def pdf(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with true <- user && Users.can?(user, :admin),
         {:ok, doc_id} <- RuleMaven.Hashid.decode(id),
         %Games.Document{pdf_path: pdf_path} when is_binary(pdf_path) <-
           Games.get_document(doc_id),
         full_path = RuleMaven.Uploads.resolve(pdf_path),
         true <- File.exists?(full_path) do
      conn
      |> put_resp_content_type("application/pdf")
      |> put_resp_header("content-disposition", "inline")
      |> send_file(200, full_path)
    else
      # 404 (not 403) so the route doesn't reveal which documents exist to
      # non-admins.
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
