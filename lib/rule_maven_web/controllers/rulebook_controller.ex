defmodule RuleMavenWeb.RulebookController do
  @moduledoc """
  Serves the extracted-text HTML view and the original PDF of a rulebook to admins only.

  Rulebooks may be copyrighted, so the original PDF is never served over HTTP
  (the `uploads` dir is no longer in `static_paths`), and the extracted-text
  HTML is gated to admins. Regular users only ever see a source's name.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.{Games, Users}

  # The HTML copy is built from a PDF's text (untrusted) and carries its own inline theme
  # script and styles. Sandboxed without allow-same-origin: its scripts run in an opaque
  # origin, so even markup that slipped into an older copy can't reach the session or the
  # app. (The saved light/dark choice doesn't persist there; the toggle still works.)
  @html_csp "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " <>
              "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; " <>
              "sandbox allow-scripts"

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
      |> put_resp_header("content-security-policy", @html_csp)
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
      # Browsers' built-in PDF viewers can refuse to render under the strict page policy:
      # keep Phoenix's default for the PDF itself.
      |> put_resp_header("content-security-policy", "base-uri 'self'; frame-ancestors 'self';")
      |> delete_resp_header("x-frame-options")
      |> send_file(200, full_path)
    else
      # 404 (not 403) so the route doesn't reveal which documents exist to
      # non-admins.
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
