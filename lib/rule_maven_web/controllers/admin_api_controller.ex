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
  alias RuleMaven.ManualImport.{Answers, Corrections, Enrichments}

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
  POST /api/admin/games/:game/content — `{"enrichments": …, "answers": […],
  "expansions": [expansion game token, …]}`. Answers are owned by the token's
  user and rejected unless every citation verifies against the game's chunks.
  With `expansions`, the answers are for the game played with those
  expansions (citations may quote their rulebooks too).
  """
  def create_content(conn, %{"game" => token} = params) do
    with_game(conn, token, fn game ->
      with {:ok, expansion_ids} <- decode_tokens(params["expansions"] || []),
           {:ok, steps} <- import_enrichments(game, params["enrichments"]),
           {:ok, answers} <-
             import_answers(game, conn.assigns.current_user, params["answers"], expansion_ids) do
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

  @doc """
  GET /api/admin/corrections[?game=token] — answers players reported or
  thumbed down that nobody has reviewed yet (`ManualImport.Corrections`).
  """
  def corrections(conn, params) do
    with {:ok, opts} <- game_filter(params["game"]) do
      queue = Corrections.queue(opts)
      names = Corrections.game_names(queue)

      json(conn, %{
        queue:
          Enum.map(queue, &Corrections.entry_payload(&1, names, fn id -> Hashid.encode(id) end))
      })
    else
      _ -> error(conn, 404, :not_found)
    end
  end

  @doc """
  POST /api/admin/corrections — `{"corrections": [{"question": token,
  "action": "correct", "answer", "verdict", "citations", "note"} |
  {"question": token, "action": "uphold", "note"}]}`. Corrections must cite
  verifiable quotes; results come back per question token.
  """
  def apply_corrections(conn, %{"corrections" => entries}) when is_list(entries) do
    results =
      for entry <- entries do
        case Hashid.decode(to_string(entry["question"])) do
          {:ok, id} ->
            [{_id, result}] =
              Corrections.apply_all([Map.put(entry, "question", id)], conn.assigns.current_user)

            %{question: entry["question"], ok: result == :ok, error: error_text(result)}

          :error ->
            %{question: entry["question"], ok: false, error: "bad token"}
        end
      end

    json(conn, %{results: results})
  end

  def apply_corrections(conn, _), do: error(conn, 422, :corrections_must_be_a_list)

  defp game_filter(nil), do: {:ok, []}

  defp game_filter(token) do
    case Hashid.decode(token) do
      {:ok, id} -> {:ok, [game_id: id]}
      :error -> :error
    end
  end

  defp error_text(:ok), do: nil
  defp error_text({:error, reason}), do: inspect(reason)

  defp import_enrichments(_game, nil), do: {:ok, []}

  defp import_enrichments(game, data) when is_map(data),
    do: Enrichments.import(game, drop_symbol_image_paths(data))

  defp import_enrichments(_game, _), do: {:error, :enrichments_must_be_an_object}

  # A symbol's "image_path" is a server-local file for the mix task; from the
  # network it would read any server file into the public icon store. The API
  # takes images as "image_base64" only.
  defp drop_symbol_image_paths(%{"symbols" => syms} = data) when is_list(syms),
    do:
      Map.put(
        data,
        "symbols",
        Enum.map(syms, &if(is_map(&1), do: Map.delete(&1, "image_path"), else: &1))
      )

  defp drop_symbol_image_paths(data), do: data

  defp import_answers(_game, _user, nil, _expansion_ids), do: {:ok, %{}}

  defp import_answers(game, user, entries, expansion_ids) when is_list(entries) do
    with {:ok, r} <- Answers.import(game, user, entries, expansion_ids: expansion_ids) do
      {:ok,
       %{
         imported: r.imported,
         skipped: r.skipped,
         errors: for({q, reason} <- r.errors, do: %{question: q, reason: inspect(reason)})
       }}
    end
  end

  defp import_answers(_game, _user, _, _), do: {:error, :answers_must_be_a_list}

  defp decode_tokens(tokens) when is_list(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, acc} ->
      case Hashid.decode(token) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        :error -> {:halt, {:error, {:bad_expansion_token, token}}}
      end
    end)
  end

  defp decode_tokens(_), do: {:error, :expansions_must_be_a_list}

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
