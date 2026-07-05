defmodule RuleMaven.Workers.AskWorker do
  @moduledoc """
  Background LLM ask. Enqueue from LiveView to avoid blocking the process.
  Calls LLM.ask, updates the pre-logged question + answer, then broadcasts
  result via PubSub.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  alias RuleMaven.{Games, Jobs}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: args}) do
    game_id = args["game_id"]
    question_log_id = args["question_log_id"]
    question = args["question"]
    expansion_ids = args["expansion_ids"] || []
    user_id = args["user_id"]
    skip_pool = args["skip_pool"] || false
    voice = args["voice"] || "neutral"

    recent_context =
      (args["recent_context"] || [])
      |> Enum.map(fn %{"q" => q, "a" => a} -> {q, a} end)

    game = Games.get_game!(game_id)

    # One run per question. High-volume, so the panel hides "ask" by default; the
    # admin can toggle it on. Every terminal branch below closes this run, so it
    # never lingers as "running".
    run =
      Jobs.start_run("ask", {"question", question_log_id}, ask_label(question),
        oban_job_id: oban_id
      )

    cond do
      # Re-check the kill switch at execution time: a job may have been queued
      # (or is retrying) before an admin flipped the switch off, and it must not
      # spend after that. Persist a friendly answer and close the run gracefully
      # rather than leaving the question stuck on "Thinking...".
      RuleMaven.Settings.asks_disabled?() ->
        handle_disabled(run, game_id, question_log_id, question)

      RuleMaven.Security.prompt_injection?(question) ->
        if ql = get_question_log!(question_log_id) do
          case Games.log_question_update(ql, %{
                 answer: "⚠️ This question was blocked by the security filter.",
                 refused: true,
                 blocked: true
               }) do
            {:ok, _} ->
              Phoenix.PubSub.broadcast(
                RuleMaven.PubSub,
                "game:#{game_id}",
                {:ask_complete,
                 %{
                   question_log_id: question_log_id,
                   faq_hit: false,
                   followup: false,
                   followups: [],
                   also_asked: [],
                   cited_page: nil,
                   refused: true,
                   raw_response: nil
                 }}
              )

            {:error, _} ->
              :ok
          end
        end

        Jobs.finish_run(run, "done", "Blocked by security filter.")
        :ok

      true ->
        Jobs.event(
          run,
          :info,
          "Answering against the rulebook#{if expansion_ids != [], do: " (+#{length(expansion_ids)} expansion(s))", else: ""}…"
        )

        case RuleMaven.LLM.ask(game, question, expansion_ids, recent_context,
               user_id: user_id,
               skip_pool: skip_pool,
               voice: voice
             ) do
          {:ok, %{answer: raw_answer} = llm_result} ->
            answer =
              cond do
                is_nil(raw_answer) || String.trim(raw_answer) == "" ->
                  "⚠️ The AI returned an empty response. Please retry."

                suspicious_output?(raw_answer) ->
                  "⚠️ The AI returned an unexpected response format. Please retry."

                true ->
                  stripped = strip_question_echo(raw_answer, question)
                  if String.trim(stripped) == "", do: raw_answer, else: stripped
              end

            ql = get_question_log!(question_log_id)
            source_id = llm_result[:source_question_log_id]

            # Answer-side dedup: a fresh answer (not a cache hit) that is identical
            # to one of the asker's own prior answers — two differently-worded
            # questions that produced the same ruling. Redirect there instead of
            # persisting a duplicate. Own rows only, so no cross-user exposure.
            answer_dup =
              ql && !llm_result[:pool_hit] && !refused?(answer) &&
                Games.find_user_answer_duplicate(
                  game_id,
                  user_id,
                  answer,
                  question_log_id,
                  Enum.sort(expansion_ids)
                )

            cond do
              is_nil(ql) ->
                # Question row vanished (deleted by a retry) — close the run so it
                # doesn't linger as running.
                Jobs.finish_run(run, "done", "Question no longer exists.")

              # Same-user duplicate: the asker already has this exact answer, so
              # redirect them to it and drop this provisional row instead of
              # persisting a second copy. Only when the source still exists; cross-
              # user pool/community hits fall through and keep the anonymized copy.
              llm_result[:same_user_hit] && source_id && get_question_log!(source_id) ->
                Games.delete_question(ql)

                Phoenix.PubSub.broadcast(
                  RuleMaven.PubSub,
                  "game:#{game_id}",
                  {:ask_redirect,
                   %{question_log_id: question_log_id, source_question_log_id: source_id}}
                )

                Jobs.finish_run(
                  run,
                  "done",
                  "Duplicate of your prior question — redirected to ##{source_id}."
                )

              answer_dup ->
                Games.delete_question(ql)

                Phoenix.PubSub.broadcast(
                  RuleMaven.PubSub,
                  "game:#{game_id}",
                  {:ask_redirect,
                   %{question_log_id: question_log_id, source_question_log_id: answer_dup.id}}
                )

                Jobs.finish_run(
                  run,
                  "done",
                  "Duplicate answer — redirected to ##{answer_dup.id}."
                )

              true ->
                {valid_citations, citation_valid} =
                  if llm_result[:pool_hit] do
                    # Cache/pool hit: this answer was already validated once,
                    # when it was first created (against real retrieved
                    # chunks). There's no retrieval on a cache serve — no
                    # `source_chunks` to re-validate against — so trust the
                    # pooled values and pass them through unchanged instead
                    # of re-running validation against zero chunks (which
                    # would always fail and silently drop the citation).
                    {llm_result[:citations] || [], llm_result[:citation_valid] || false}
                  else
                    raw_citations =
                      case llm_result[:citations] do
                        list when is_list(list) and list != [] ->
                          list

                        _ ->
                          # Legacy/mock path: only the singular scalar fields were
                          # supplied. Wrap them so downstream processing is uniform.
                          if llm_result[:cited_passage] || llm_result[:cited_page] ||
                               llm_result[:cited_source] do
                            [
                              %{
                                "quote" => llm_result[:cited_passage],
                                "page" => llm_result[:cited_page],
                                "source" => llm_result[:cited_source]
                              }
                            ]
                          else
                            []
                          end
                      end

                    processed_citations =
                      Enum.map(raw_citations, &process_citation(&1, llm_result[:source_chunks]))

                    valid =
                      RuleMaven.Games.Citations.valid_citations(
                        processed_citations,
                        llm_result[:source_chunks]
                      )

                    {valid, valid != []}
                  end

                primary =
                  List.first(valid_citations) || %{"quote" => nil, "page" => nil, "source" => nil}

                passage = primary["quote"]
                cited_page = primary["page"]
                cited_source = primary["source"]

                refused? = refused?(answer)

                cleaned =
                  llm_result[:cleaned_question]
                  |> to_string()
                  |> String.trim()
                  |> strip_game_name(game.name)

                # Sanity check: cleaned must be shorter than the answer and
                # not exceed a reasonable question length, else the LLM put
                # answer content in the CLEANED block — discard it.
                cleaned =
                  if cleaned != "" and
                       String.length(cleaned) <= 250 and
                       String.length(cleaned) <= String.length(answer) * 2 do
                    cleaned
                  else
                    ""
                  end

                update_attrs = %{
                  answer: answer,
                  # Preserve the raw question as typed; the normalized form is stored
                  # separately in cleaned_question and is what gets displayed.
                  question: question,
                  cited_passage: passage,
                  cited_page: cited_page,
                  cited_source: cited_source,
                  citations: valid_citations,
                  citation_valid: citation_valid,
                  refused: refused?,
                  verdict: if(refused?, do: "silent", else: llm_result[:verdict]),
                  followups: if(refused?, do: [], else: llm_result[:followups] || []),
                  also_asked: if(refused?, do: [], else: llm_result[:also_asked] || []),
                  cleaned_question: if(cleaned != "", do: cleaned, else: nil),
                  raw_response: llm_result[:raw_response],
                  llm_provider: llm_result[:provider],
                  llm_model: llm_result[:model],
                  pool_source_id: llm_result[:source_question_log_id],
                  question_embedding: llm_result[:question_embedding]
                }

                case Games.log_question_update(ql, update_attrs) do
                  {:ok, updated} ->
                    pool_hit? = llm_result[:pool_hit] || false

                    unless refused? do
                      RuleMaven.Workers.TagQuestionWorker.enqueue(question_log_id, game_id)
                      # Fresh, citation-backed answers become cache-eligible. Pool hits
                      # are duplicates of an existing pooled row — don't re-pool them.
                      unless pool_hit?, do: Games.mark_pooled(updated)
                    end

                    # Persona-direct path: the single ask call already produced the
                    # styled answer, so cache it now instead of enqueueing a
                    # separate VoiceWorker restyle for this (question, voice) pair.
                    styled_answer = llm_result[:styled_answer]
                    styled_voice = llm_result[:styled_voice]

                    # `styled_voice != "neutral"` is defense-in-depth: a neutral ask
                    # never produces a styled_answer in the first place (voice_style_block
                    # returns "" for "neutral"), so this branch of the guard can't
                    # currently be reached — kept in case that ever changes.
                    store_direct? =
                      styled_answer && styled_voice && styled_voice != "neutral" &&
                        not refused?

                    if store_direct? do
                      case RuleMaven.Voices.store_direct(question_log_id, styled_voice, styled_answer) do
                        :ok ->
                          :ok

                        {:error, reason} ->
                          require Logger

                          Logger.warning(
                            "AskWorker: failed to cache styled answer for question #{question_log_id} voice #{styled_voice}: #{inspect(reason)}"
                          )
                      end
                    end

                    Phoenix.PubSub.broadcast(
                      RuleMaven.PubSub,
                      "game:#{game_id}",
                      {:ask_complete,
                       %{
                         question_log_id: question_log_id,
                         faq_hit: llm_result[:faq_hit] || false,
                         pool_hit: pool_hit?,
                         tier: llm_result[:tier],
                         verified: llm_result[:verified] || false,
                         source_question_log_id: llm_result[:source_question_log_id],
                         followups: if(refused?, do: [], else: llm_result[:followups] || []),
                         also_asked: if(refused?, do: [], else: llm_result[:also_asked] || []),
                         cited_page: cited_page,
                         refused: refused?,
                         verdict: if(refused?, do: "silent", else: llm_result[:verdict]),
                         raw_response: llm_result[:raw_response],
                         # Only ever carry a styled answer when the DB write above
                         # actually happened (i.e. store_direct? was true) — a
                         # refused question must not broadcast a styled answer even
                         # if the model ignored the "don't style a refusal" framing.
                         styled_voice: if(store_direct?, do: styled_voice, else: nil),
                         styled_answer: if(store_direct?, do: styled_answer, else: nil)
                       }}
                    )

                    summary =
                      cond do
                        refused? ->
                          "Refused — not in rulebook."

                        pool_hit? ->
                          "Answered from cache — #{String.length(answer)} chars, page #{cited_page || "—"}."

                        true ->
                          "Answered — #{String.length(answer)} chars, page #{cited_page || "—"}#{if citation_valid, do: "", else: " (citation unverified)"}."
                      end

                    Jobs.finish_run(run, "done", summary)

                  {:error, changeset} ->
                    require Logger

                    Logger.error(
                      "AskWorker DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
                    )

                    Phoenix.PubSub.broadcast(
                      RuleMaven.PubSub,
                      "game:#{game_id}",
                      {:ask_error,
                       %{
                         question_log_id: question_log_id,
                         question: question,
                         error: "Failed to save answer"
                       }}
                    )

                    Jobs.finish_run(run, "failed", "Failed to save answer.")
                end
            end

            :ok

          {:error, reason} ->
            require Logger
            Logger.error("AskWorker failed for game #{game_id}: #{reason}")

            friendly =
              cond do
                is_binary(reason) && String.contains?(reason, "timeout") ->
                  "⚠️ The AI took too long to respond. Please retry."

                is_binary(reason) && String.contains?(reason, "rate") ->
                  "⚠️ Too many requests — please wait a moment and retry."

                is_binary(reason) && String.contains?(reason, "context") ->
                  "⚠️ Question too long for the AI to process. Try a shorter question."

                true ->
                  "⚠️ Something went wrong. Please retry."
              end

            if ql = get_question_log!(question_log_id) do
              case Games.log_question_update(ql, %{answer: friendly}) do
                {:ok, _updated} ->
                  Phoenix.PubSub.broadcast(
                    RuleMaven.PubSub,
                    "game:#{game_id}",
                    {:ask_error,
                     %{question_log_id: question_log_id, question: question, error: reason}}
                  )

                {:error, changeset} ->
                  Logger.error(
                    "AskWorker error DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
                  )
              end
            end

            Jobs.finish_run(run, "failed", to_string(reason))
            :ok
        end
    end
  end

  # Persists a friendly "paused" answer and closes the run without ever calling
  # the LLM — mirrors the {:error, reason} terminal branch below (friendly
  # answer + :ask_error broadcast + finish_run), so the LiveView unblocks the
  # "Thinking..." row the same way a failed ask would.
  defp handle_disabled(run, game_id, question_log_id, question) do
    message = RuleMaven.Settings.asks_disabled_message()

    if ql = get_question_log!(question_log_id) do
      case Games.log_question_update(ql, %{answer: message}) do
        {:ok, _updated} ->
          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            "game:#{game_id}",
            {:ask_error, %{question_log_id: question_log_id, question: question, error: message}}
          )

        {:error, changeset} ->
          require Logger

          Logger.error(
            "AskWorker disabled-switch DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
          )
      end
    end

    Jobs.finish_run(run, "done", "Skipped — question answering is paused.")
    :ok
  end

  # Short left-rail label: the question, truncated.
  defp ask_label(question) when is_binary(question) do
    q = String.trim(question)
    if String.length(q) > 60, do: String.slice(q, 0, 57) <> "…", else: q
  end

  defp ask_label(_), do: "Ask"

  defp get_question_log(id) do
    import Ecto.Query
    alias RuleMaven.Games.QuestionLog

    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  defp get_question_log!(id) do
    case get_question_log(id) do
      nil ->
        require Logger
        Logger.warning("AskWorker: question_log #{id} not found, likely deleted by retry")
        nil

      q ->
        q
    end
  end

  # Detect if LLM output looks encoded/transformed rather than plain English prose
  defp suspicious_output?(text) do
    trimmed = String.trim(text)
    len = String.length(trimmed)

    return_early = len < 10

    if return_early do
      false
    else
      # Count characters outside normal prose range (letters, digits, spaces, common punctuation)
      prose_chars =
        Regex.scan(~r/[a-zA-Z0-9 \t\n\r.,!?;:()\-'"\/\[\]%&*@#$€£°]/, trimmed) |> length()

      non_prose_ratio = 1 - prose_chars / len

      # Base64 blocks: long runs of base64 chars with no prose spaces
      looks_base64 =
        Regex.match?(~r/\A[A-Za-z0-9+\/=\n\r]{40,}\z/, trimmed) ||
          Regex.match?(~r/(?:[A-Za-z0-9+\/]{40,}={0,2})/, trimmed)

      # Hex dump: sequences of hex pairs
      looks_hex = Regex.match?(~r/(?:[0-9a-fA-F]{2}\s){10,}/, trimmed)

      # Very high proportion of non-prose characters
      non_prose_ratio > 0.4 || looks_base64 || looks_hex
    end
  end

  # Per-citation-entry cleanup: strips [Page N]/(Page N) markers from the
  # quote (they're only needed to recover the page below), recovers a missing
  # page the same way the old single-citation path did (trust the model's
  # own page first, else parse it out of the raw quote, else infer it by
  # matching the quote back to its source chunk), and canonicalizes the
  # source label against the actual retrieved chunk labels.
  defp process_citation(%{} = c, source_chunks) do
    raw_quote = c["quote"]

    quote_clean =
      if raw_quote do
        raw_quote
        |> String.replace(~r/\[Page\s*\d+\]/i, "")
        |> String.replace(~r/\(Page\s*\d+\)/i, "")
        |> String.trim()
      end

    resolved_page =
      c["page"] ||
        parse_cited_page(raw_quote) ||
        infer_page_from_chunks(quote_clean, source_chunks)

    resolved_source = RuleMaven.Games.Citations.canonical_source(c["source"], source_chunks)

    %{"quote" => quote_clean, "page" => resolved_page, "source" => resolved_source}
  end

  defp parse_cited_page(nil), do: nil

  defp parse_cited_page(passage) do
    case Regex.run(~r/\[Page\s+(\d+)\]/, passage) do
      [_, num] -> String.to_integer(num)
      nil -> nil
    end
  end

  # Recover the page when the model dropped the [Page N] marker: find the source
  # chunk whose text contains the cited passage, then read that chunk's marker.
  defp infer_page_from_chunks(passage, chunks)
       when is_binary(passage) and is_list(chunks) and chunks != [] do
    needle =
      passage
      |> normalize_for_match()
      |> String.split(" ", trim: true)
      |> Enum.take(10)
      |> Enum.join(" ")

    if String.length(needle) < 12 do
      nil
    else
      Enum.find_value(chunks, fn chunk ->
        text = chunk_text(chunk)

        if String.contains?(normalize_for_match(text), needle),
          do: parse_cited_page(text),
          else: nil
      end)
    end
  end

  defp infer_page_from_chunks(_passage, _chunks), do: nil

  defp chunk_text(%{content: content}), do: content
  defp chunk_text(text) when is_binary(text), do: text
  defp chunk_text(_), do: ""

  defp normalize_for_match(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\[page\s*\d+\]/i, " ")
    |> String.replace(~r/[^a-z0-9 ]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @refusal_phrase "The rulebook does not cover this question."

  defp refused?(answer) do
    String.trim(answer) == @refusal_phrase
  end

  defp strip_game_name("", _), do: ""

  defp strip_game_name(question, game_name) when is_binary(question) and is_binary(game_name) do
    escaped = Regex.escape(game_name)
    # Strip " in Game Name" or " in Game Name?" suffix
    question
    |> String.replace(~r/ in #{escaped}\??$/i, "")
    |> String.replace(~r/ \(#{escaped}\)\??$/i, "")
    |> String.trim()
    |> then(fn q -> if String.ends_with?(q, "?"), do: q, else: q <> "?" end)
  end

  defp strip_game_name(question, _), do: question

  defp strip_question_echo(answer, question) do
    q = String.trim(question)

    case String.split(answer, "\n", parts: 2) do
      [first_line | rest] ->
        fl = String.trim(first_line)

        similar? =
          String.downcase(fl) == String.downcase(q) ||
            (String.ends_with?(fl, "?") &&
               String.jaro_distance(String.downcase(fl), String.downcase(q)) > 0.82)

        if similar?, do: String.trim(Enum.join(rest, "\n")), else: answer

      _ ->
        answer
    end
  end
end
