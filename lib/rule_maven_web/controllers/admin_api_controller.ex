defmodule RuleMavenWeb.AdminApiController do
  @moduledoc """
  Remote Prepare for super admins (bearer token, see `RuleMavenWeb.ApiAuth`):
  lets an operator outside the app — e.g. Claude in a dev session — transcribe a
  rulebook and author its content, then push the result to any environment.
  Every action delegates to the same code the mix tasks use
  (`ManualImport`, `ManualImport.Enrichments`/`Answers`, `Readiness`), so a
  remote import is indistinguishable from a local one. Games and documents
  are addressed by `Hashid` token, never raw id.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.{Audit, Games, Hashid, ManualImport, Readiness, Repo}
  alias RuleMaven.Games.Document
  alias RuleMaven.ManualImport.{Answers, Enrichments}

  @doc "GET /api/admin/games?q=name — find a game's token."
  def index(conn, params) do
    games =
      for g <- Games.search_catalog(params["q"] || "", limit: 25),
          do: %{token: Hashid.encode(g.id), name: g.name, year: g.year_published}

    json(conn, %{games: games})
  end

  @doc "GET /api/admin/games/:game — readiness steps and documents."
  def show(conn, %{"game" => token}) do
    with_game(conn, token, &json(conn, status_payload(&1)))
  end

  @doc """
  POST /api/admin/games/:game/documents — import transcribed pages (body:
  `ManualImport.import/2` input). Use `pdf_url` to attach the source PDF.
  """
  def create_document(conn, %{"game" => token} = params) do
    with_game(conn, token, fn game ->
      # "pdf" is a server-local file path for the mix task; from the network it
      # would copy any readable server file into the public uploads dir.
      attrs = Map.drop(params, ["game", "pdf"])

      case ManualImport.import(game, attrs) do
        {:ok, doc} ->
          audit(conn, "api.import_pages", game, %{document_id: doc.id, pages: length(doc.pages)})

          conn
          |> put_status(:created)
          |> json(%{document: doc_payload(doc), status: status_payload(game)})

        {:error, reason} ->
          error(conn, 422, reason)
      end
    end)
  end

  @doc "DELETE /api/admin/games/:game/documents/:doc — remove a document (e.g. before re-importing)."
  def delete_document(conn, %{"game" => token, "doc" => doc_token}) do
    with_game(conn, token, fn game ->
      with {:ok, id} <- Hashid.decode(doc_token),
           %Document{game_id: game_id} = doc when game_id == game.id <- Repo.get(Document, id),
           {:ok, _} <- Games.delete_document(doc) do
        Readiness.recompute(game)
        audit(conn, "api.delete_document", game, %{document_id: id})
        json(conn, status_payload(game))
      else
        {:error, reason} -> error(conn, 422, reason)
        _ -> error(conn, 404, :not_found)
      end
    end)
  end

  @doc """
  POST /api/admin/games/:game/content — `{"enrichments": …, "answers": […]}`.
  Answers are owned by the token's user and rejected unless every citation
  verifies against the game's chunks.
  """
  def create_content(conn, %{"game" => token} = params) do
    with_game(conn, token, fn game ->
      with {:ok, steps} <- import_enrichments(game, params["enrichments"]),
           {:ok, answers} <- import_answers(game, conn.assigns.current_user, params["answers"]) do
        audit(conn, "api.import_content", game, %{steps: steps, answers: answers[:imported]})
        json(conn, %{enrichments: steps, answers: answers, status: status_payload(game)})
      else
        {:error, reason} -> error(conn, 422, reason)
      end
    end)
  end

  @doc "POST /api/admin/games/:game/publish — approve publish (audited)."
  def publish(conn, %{"game" => token}) do
    with_game(conn, token, fn game ->
      playable = Readiness.approve_publish(game, conn.assigns.current_user)
      json(conn, Map.put(status_payload(game), :playable, playable))
    end)
  end

  defp import_enrichments(_game, nil), do: {:ok, []}
  defp import_enrichments(game, data), do: Enrichments.import(game, data)

  defp import_answers(_game, _user, nil), do: {:ok, %{}}

  defp import_answers(game, user, entries) when is_list(entries) do
    {:ok, r} = Answers.import(game, user, entries)

    {:ok,
     %{
       imported: r.imported,
       skipped: r.skipped,
       errors: for({q, reason} <- r.errors, do: %{question: q, reason: inspect(reason)})
     }}
  end

  defp import_answers(_game, _user, _), do: {:error, :answers_must_be_a_list}

  defp with_game(conn, token, fun) do
    case Games.get_game_by_token(token) do
      nil -> error(conn, 404, :not_found)
      game -> fun.(game)
    end
  end

  defp status_payload(game) do
    %{
      game: %{token: Hashid.encode(game.id), name: game.name},
      steps: for(s <- Readiness.state(game), do: %{id: s.id, state: s.state}),
      documents: Enum.map(Games.list_documents(game), &doc_payload/1)
    }
  end

  defp doc_payload(doc) do
    %{
      token: Hashid.encode(doc.id),
      label: doc.label,
      kind: doc.kind,
      page_count: doc.page_count,
      has_pdf: is_binary(doc.pdf_path)
    }
  end

  defp audit(conn, action, game, metadata) do
    Audit.log(conn.assigns.current_user, action,
      target_type: "game",
      target_id: game.id,
      target_label: game.name,
      metadata: metadata
    )
  end

  defp error(conn, status, reason) do
    conn |> put_status(status) |> json(%{error: inspect(reason)})
  end
end
