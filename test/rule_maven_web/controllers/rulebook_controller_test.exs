defmodule RuleMavenWeb.RulebookControllerTest do
  @moduledoc """
  Covers the admin-gated PDF endpoint. Rulebooks may be copyrighted, so the
  PDF is only reachable by admins, and every failure mode is a 404 (never a
  403) so the route doesn't reveal which documents exist.
  """

  use RuleMavenWeb.ConnCase, async: true
  import RuleMaven.GamesFixtures

  alias RuleMaven.Hashid

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user!(prefix, role \\ "user") do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  # Writes a real PDF file under priv/static so send_file has something to
  # serve; removed on exit. The relative path is unique per test run.
  defp create_pdf_doc!(game) do
    rel_path = "uploads/rulebooks/test_#{System.unique_integer([:positive])}.pdf"
    abs_path = Application.app_dir(:rule_maven, "priv/static/#{rel_path}")
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, "%PDF-1.4 fake test pdf")
    on_exit(fn -> File.rm(abs_path) end)

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: rel_path,
        pages: []
      })

    doc
  end

  setup %{conn: conn} do
    game = game_fixture(%{name: "PDF Test Game", bgg_id: 91_001})
    %{conn: conn, game: game}
  end

  test "admin gets the PDF inline", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin", "admin")
    doc = create_pdf_doc!(game)

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "inline"
    assert conn.resp_body =~ "%PDF-1.4"
  end

  test "non-admin gets 404", %{conn: conn, game: game} do
    user = create_user!("pdf_regular")
    doc = create_pdf_doc!(game)

    conn = conn |> login(user) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "anonymous gets 404", %{conn: conn, game: game} do
    doc = create_pdf_doc!(game)

    conn = get(conn, ~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "document without a pdf_path 404s for admins", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin_nopath", "admin")

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "No PDF",
        pages: []
      })

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "pdf_path pointing at a missing file 404s for admins", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin_gone", "admin")

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Gone PDF",
        pdf_path: "uploads/rulebooks/does_not_exist_#{System.unique_integer([:positive])}.pdf",
        pages: []
      })

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end
end
