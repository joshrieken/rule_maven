defmodule RuleMavenWeb.AdminApiControllerTest do
  @moduledoc """
  Remote Prepare API: bearer-token auth (super admin only, re-checked per
  request) and the import → content → publish flow, which delegates to the same
  ManualImport code the mix tasks use.
  """
  use RuleMavenWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias RuleMaven.{Games, Hashid, Repo, Users}
  alias RuleMaven.Games.Document

  @page_text "At Mimic's location, discard [blue circle token: 6+] to battle Mimic and defeat it!"

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    {:ok, admin} =
      Users.create_user(%{
        username: "api_owner",
        email: "api_owner@test.com",
        password: "password1234",
        role: "user"
      })

    {:ok, admin} = Users.set_super_admin(admin, true)
    {:ok, token} = Users.create_api_token(admin)
    {:ok, game} = Games.create_game(%{name: "Api Game #{System.unique_integer([:positive])}"})

    %{admin: admin, token: token, game: game, gtok: Hashid.encode(game.id)}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp import_pages(conn, token, gtok, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "label" => "Core Rulebook",
          "pages" => [%{"sheet" => 1, "printed" => 1, "text" => @page_text}]
        },
        extra
      )

    conn |> authed(token) |> post(~p"/api/admin/games/#{gtok}/documents", body)
  end

  describe "auth" do
    test "missing or bogus token is 401", %{conn: conn, gtok: gtok} do
      assert conn |> get(~p"/api/admin/games/#{gtok}") |> json_response(401)
      assert conn |> authed("nope") |> get(~p"/api/admin/games/#{gtok}") |> json_response(401)
    end

    test "non super admins cannot mint a token" do
      {:ok, user} =
        Users.create_user(%{
          username: "plain",
          email: "plain@test.com",
          password: "password1234",
          role: "admin"
        })

      assert Users.create_api_token(user) == {:error, :not_super_admin}
    end

    test "a demoted or suspended account's token stops working", %{
      conn: conn,
      admin: admin,
      token: token,
      gtok: gtok
    } do
      assert conn |> authed(token) |> get(~p"/api/admin/games/#{gtok}") |> json_response(200)

      {:ok, demoted} = Users.set_super_admin(admin, false)

      assert build_conn()
             |> authed(token)
             |> get(~p"/api/admin/games/#{gtok}")
             |> json_response(401)

      {:ok, _} = Users.set_super_admin(demoted, true)
      Repo.update!(Ecto.Changeset.change(demoted, suspended_at: DateTime.utc_now(:second)))

      assert build_conn()
             |> authed(token)
             |> get(~p"/api/admin/games/#{gtok}")
             |> json_response(401)
    end

    test "revoked tokens stop working", %{conn: conn, admin: admin, token: token, gtok: gtok} do
      assert Users.revoke_api_tokens(admin) == 1
      assert conn |> authed(token) |> get(~p"/api/admin/games/#{gtok}") |> json_response(401)
    end
  end

  test "unknown game token is 404", %{conn: conn, token: token} do
    assert conn |> authed(token) |> get(~p"/api/admin/games/zzzzzzzz") |> json_response(404)
  end

  test "index finds games by name", %{conn: conn, token: token, game: game, gtok: gtok} do
    %{"games" => games} =
      conn |> authed(token) |> get(~p"/api/admin/games?q=#{game.name}") |> json_response(200)

    assert [%{"token" => ^gtok}] = games
  end

  test "imports pages, ignoring a server-local pdf path", %{
    conn: conn,
    token: token,
    game: game,
    gtok: gtok
  } do
    resp = conn |> import_pages(token, gtok, %{"pdf" => "mix.exs"}) |> json_response(201)

    assert %{"document" => %{"token" => dtok, "page_count" => 1, "has_pdf" => false}} = resp
    {:ok, id} = Hashid.decode(dtok)
    doc = Repo.get!(Document, id)
    assert doc.game_id == game.id
    assert doc.pdf_path == nil
  end

  test "imports content with answers owned by the token user, then publishes", %{
    conn: conn,
    token: token,
    gtok: gtok,
    admin: admin
  } do
    import_pages(conn, token, gtok) |> json_response(201)

    answers = [
      %{
        "question" => "How do I defeat the Mimic?",
        "answer" => "Discard a blue 6+ token at Mimic's location.",
        "verdict" => "info",
        "citations" => [
          %{"quote" => "discard [blue circle token: 6+] to battle Mimic", "page" => 1}
        ]
      }
    ]

    resp =
      build_conn()
      |> authed(token)
      |> post(~p"/api/admin/games/#{gtok}/content", %{"answers" => answers})
      |> json_response(200)

    assert %{"answers" => %{"imported" => 1, "errors" => []}} = resp

    assert Repo.exists?(
             from q in RuleMaven.Games.QuestionLog,
               where: q.user_id == ^admin.id and q.question == "How do I defeat the Mimic?"
           )

    assert %{"playable" => _} =
             build_conn()
             |> authed(token)
             |> post(~p"/api/admin/games/#{gtok}/publish")
             |> json_response(200)
  end

  test "rejects a non-list answers payload", %{conn: conn, token: token, gtok: gtok} do
    assert conn
           |> authed(token)
           |> post(~p"/api/admin/games/#{gtok}/content", %{"answers" => "x"})
           |> json_response(422)
  end

  test "corrections: lists the review queue and applies a fix by token", %{
    conn: conn,
    token: token,
    gtok: gtok,
    admin: admin
  } do
    import_pages(conn, token, gtok) |> json_response(201)
    {:ok, game_id} = Hashid.decode(gtok)

    {:ok, row} =
      Games.log_question(%{
        game_id: game_id,
        question: "How do I beat the Mimic?",
        answer: "You can't.",
        verdict: "info",
        expansion_ids: [],
        feedback: "down"
      })

    qtok = Hashid.encode(row.id)

    %{"queue" => [%{"question" => ^qtok, "game" => ^gtok, "thumbs_down" => true}]} =
      build_conn()
      |> authed(token)
      |> get(~p"/api/admin/corrections?game=#{gtok}")
      |> json_response(200)

    fix = %{
      "question" => qtok,
      "action" => "correct",
      "answer" => "Discard a blue 6+ token at Mimic's location.",
      "verdict" => "info",
      "citations" => [
        %{"quote" => "discard [blue circle token: 6+] to battle Mimic", "page" => 1}
      ]
    }

    %{"results" => [%{"ok" => true}, %{"ok" => false, "error" => "bad token"}]} =
      build_conn()
      |> authed(token)
      |> post(~p"/api/admin/corrections", %{
        "corrections" => [fix, %{"question" => "!!", "action" => "uphold"}]
      })
      |> json_response(200)

    assert Repo.get!(RuleMaven.Games.QuestionLog, row.id).llm_provider == "manual"
    assert admin.id
  end

  test "deletes a document only through its own game", %{conn: conn, token: token, gtok: gtok} do
    %{"document" => %{"token" => dtok}} = conn |> import_pages(token, gtok) |> json_response(201)

    {:ok, other} = Games.create_game(%{name: "Other #{System.unique_integer([:positive])}"})
    otok = Hashid.encode(other.id)

    assert build_conn()
           |> authed(token)
           |> delete(~p"/api/admin/games/#{otok}/documents/#{dtok}")
           |> json_response(404)

    assert %{"documents" => []} =
             build_conn()
             |> authed(token)
             |> delete(~p"/api/admin/games/#{gtok}/documents/#{dtok}")
             |> json_response(200)
  end
end
