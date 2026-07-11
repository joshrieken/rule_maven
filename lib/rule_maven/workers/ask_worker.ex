defmodule RuleMaven.Workers.AskWorker do
  @moduledoc """
  Background LLM ask. Enqueue from LiveView to avoid blocking the process.
  Calls LLM.ask, updates the pre-logged question + answer, then broadcasts
  result via PubSub.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  require Logger

  alias RuleMaven.{Games, Jobs}
  alias RuleMaven.Games.QuestionLog

  # Hard wall-clock ceiling on a whole ask. LLM.ask's only internal limit is
  # the 60s @ask_stream_deadline_ms, and that is checked *only* inside the
  # per-SSE-chunk callback — so an upstream stall that delivers no chunks (a
  # wedged connection, a stuck Finch pool checkout, or a hang in the
  # synchronous pre-stream steps) never trips it, and the job runs forever:
  # the question stays pinned on "Thinking..." and the Oban slot leaks. Cap
  # the entire call (well above 60s stream + a possible runaway re-generation
  # + critic + restyle) so a hang surfaces as a normal retryable timeout.
  @ask_hard_timeout_ms 180_000

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, max_attempts: max_attempts, args: args} = job) do
    do_perform(job)
  rescue
    e ->
      # Every terminal write on this row — the "⚠️" answer, the :ask_error
      # broadcast, the closed job_run — lives on a RETURN-VALUE path
      # (`{:error, reason}` from LLM.ask, or run_bounded's timeout). A RAISE
      # bypasses all of them, and `run_bounded/2` doesn't help: Task.async links,
      # so an abnormal exit kills this process before `Task.yield` ever returns.
      #
      # The row is then stranded on "Thinking..." with no `error_kind`, which means
      # no retry button — and `pending_count` is recomputed from the DB on every
      # mount, so the row permanently consumes one of the user's concurrency slots
      # for that game. Unreachable, unclearable, forever.
      #
      # Only finalize on the LAST attempt: a transient raise should still get its
      # Oban retry. Then reraise, so Oban records the exception and discards the
      # job rather than silently swallowing a bug.
      if attempt >= max_attempts do
        finalize_crashed_ask(args, e)
      end

      reraise e, __STACKTRACE__
  end

  # Puts the row into the same terminal shape the `{:error, reason}` branch
  # produces, so a crashed ask is indistinguishable from a failed one to the UI.
  defp finalize_crashed_ask(args, exception) do
    question_log_id = args["question_log_id"]
    game_id = args["game_id"]

    Logger.error(
      "AskWorker crashed for question #{inspect(question_log_id)}: #{Exception.message(exception)}"
    )

    # Only a row still STUCK on "Thinking..." may be overwritten. A last-attempt
    # crash can fire AFTER `log_question_update` has already written the real
    # answer (a raise in broadcast_complete, Jobs.finish_run, a post-answer
    # enqueue — the commit's own `answered_already?` note lists these), and there
    # `is_nil(error_kind)` is TRUE for a perfectly good answer. Guarding on
    # error_kind alone would clobber that answer with "⚠️" and discard the job so
    # nothing heals it. A good, refused, or already-errored row is never
    # "Thinking...", so the terminal-shape test excludes every real terminal state.
    with id when not is_nil(id) <- question_log_id,
         %QuestionLog{answer: "Thinking..."} = ql <- Games.get_question_log(id) do
      Games.log_question_update(ql, %{
        answer: "⚠️ Something went wrong. Please retry.",
        error_kind: "unknown"
      })

      Phoenix.PubSub.broadcast(
        RuleMaven.PubSub,
        "game:#{game_id}",
        {:ask_error, %{question_log_id: id, error: "crashed"}}
      )
    end

    # Scope MUST match the ask run's own scope (`start_run("ask", {"question", ...`,
    # below) — not "question_log", which is PublishCheckWorker's scope. A mismatch
    # matches zero rows, leaving the crashed ask's run "running" forever: the very
    # symptom this finalizer exists to prevent.
    #
    # `kind: "ask"` because the scope is NOT unique to this worker — a VoiceWorker
    # restyle for the same question runs under the same `{"question", id}`, and an
    # unscoped close would flip that healthy run to "failed".
    Jobs.fail_running_runs({"question", question_log_id}, "Worker crashed.", kind: "ask")
  rescue
    # Never let the cleanup itself mask the original exception.
    e -> Logger.error("AskWorker crash finalizer failed: #{inspect(e)}")
  end

  defp do_perform(%Oban.Job{id: oban_id, args: args}) do
    game_id = args["game_id"]
    question_log_id = args["question_log_id"]
    question = args["question"]
    expansion_ids = args["expansion_ids"] || []
    user_id = args["user_id"]
    skip_pool = args["skip_pool"] || false

    # The ROW is the source of truth for group membership, not the args (Oban
    # args are untrusted, and a re-queue — e.g. the admin unblock path in
    # AdminLive.Security — can omit "group_id" entirely). A row whose
    # `group_id` column is set is a group row no matter what the args say; the
    # args may only ever ADD a group_id, never drop one. Getting this wrong
    # writes `browsable: true` on a group row (only PublishCheckWorker may do
    # that) and pools a crew that opted out of contributing.
    row_group_id = row_group_id(question_log_id)
    group_id = args["group_id"] || row_group_id

    # A row that is unbrowsable while belonging to NO crew was closed on purpose:
    # either `retract_contributions/1` withdrew it (which also nilifies group_id
    # when the crew is deleted) or it is a re-ask carrying a crew's raw text. In
    # both cases `contribute_to_community?/1` sees a nil group and cheerfully
    # answers "yes, contribute" — so an admin re-queue (AdminLive.Security's
    # unblock) would put an answer the crew explicitly withdrew straight back into
    # the commons. The row's own closed flag is the only surviving marker.
    withdrawn? =
      retracted?(question_log_id) or (is_nil(group_id) and not row_browsable?(question_log_id))

    # Folds in the per-group community-contribution switch (Task 6's composer
    # toggle sets `never_pool` directly for a one-off "keep this in the crew"
    # ask; a group with `contribute_to_community: false` makes EVERY ask from
    # it never_pool, with no per-ask opt-in needed).
    never_pool =
      (args["never_pool"] || false) or withdrawn? or
        not RuleMaven.Groups.contribute_to_community?(group_id)

    skip_normalize = args["skip_normalize"] || false
    voice = args["voice"] || "neutral"

    # Tags every llm_logs row written from this process (the whole ask
    # pipeline runs synchronously here) with the question it served — see
    # RuleMaven.LLM.current_question_log_id/0 and the admin LLM-trace panel.
    Logger.metadata(question_log_id: question_log_id)

    recent_context =
      (args["recent_context"] || [])
      |> Enum.map(fn %{"q" => q, "a" => a} -> {q, a} end)

    game = Games.get_game!(game_id)

    # One run per question. High-volume, so the panel hides "ask" by default; the
    # admin can toggle it on. Every terminal branch below closes this run, so it
    # never lingers as "running".
    # Crew PROVENANCE, not a live group_id — `withdrawn?` above already folds in
    # the nilify case (`is_nil(group_id) and not row_browsable?`), plus retraction.
    # A crew row whose crew was left or deleted has a nil group_id but is still
    # crew-origin, and its raw wording must not land in the label.
    crew_origin? = not is_nil(group_id) or withdrawn?

    run =
      Jobs.start_run("ask", {"question", question_log_id}, ask_label(question, crew_origin?),
        oban_job_id: oban_id
      )

    cond do
      # Oban is at-least-once: `max_attempts: 2` plus orphan-rescue after a node
      # restart means this job can run again when the first run already wrote its
      # answer (a raise anywhere AFTER log_question_update — Jobs.finish_run,
      # TagQuestionWorker.enqueue, Voices.store_direct — re-executes the whole
      # pipeline). Without this guard the rerun pays for a second LLM call,
      # overwrites the good answer, and broadcasts a duplicate :ask_complete.
      #
      # Safe because EVERY enqueue path inserts a FRESH row with "Thinking..."
      # (resubmit_question deletes the old row before logging a new one), so a
      # legitimate first execution always finds the sentinel.
      answered_already?(question_log_id) ->
        # The first execution may have crashed AFTER persisting but BEFORE its
        # :ask_complete broadcast (mark_pooled, store_direct, etc. sit between
        # them) — without a re-broadcast the asker's LiveView shows
        # "Thinking..." forever and their pending slot never frees. The
        # handler re-reads the row, so a duplicate broadcast is harmless.
        rebroadcast_completed(game_id, question_log_id)
        Jobs.finish_run(run, "done", "Answer already present — duplicate job execution.")
        :ok

      # Row deleted (resubmit replaced it) while this job sat in the queue —
      # bail BEFORE paying for the full LLM pipeline. The old code only
      # noticed after LLM.ask returned, discarding a fully-paid answer, and
      # the orphan also held the singleflight key against the replacement job.
      is_nil(get_question_log!(question_log_id)) ->
        Jobs.finish_run(run, "done", "Question no longer exists — skipping.")
        :ok

      # Re-check the kill switch at execution time: a job may have been queued
      # (or is retrying) before an admin flipped the switch off, and it must not
      # spend after that. Persist a friendly answer and close the run gracefully
      # rather than leaving the question stuck on "Thinking...".
      not RuleMaven.Flags.enabled?(:asks) ->
        handle_disabled(run, game_id, question_log_id, question)

      # The LiveView gates asks on takedown, but a job queued moments before the
      # takedown (or already sitting in the queue) would otherwise run to
      # completion: real LLM spend and a persisted answer for a game that is
      # legally blocked. The queue is the last place to enforce this.
      Games.taken_down?(game) ->
        handle_taken_down(run, game_id, question_log_id, question)

      RuleMaven.Security.prompt_injection?(question) ->
        if ql = get_question_log!(question_log_id) do
          case Games.log_question_update(ql, %{
                 answer: "⚠️ This question was blocked by the security filter.",
                 refused: true,
                 blocked: true
               }) do
            {:ok, updated} ->
              broadcast_complete(updated, %{
                faq_hit: false,
                followup: false,
                followups: [],
                also_asked: [],
                cited_page: nil,
                refused: true,
                raw_response: nil
              })

            {:error, _} ->
              :ok
          end
        end

        Jobs.finish_run(run, "done", "Blocked by security filter.")
        :ok

      true ->
        # Pre-vet backfill: a generated (g:) voice that hasn't passed the style
        # vet can't take the single-call persona path (voice_style_block returns
        # "" for it), so this ask falls back to the on-demand restyle. Kick off
        # the vet now so later asks with this persona get the single-call path.
        if String.starts_with?(voice, "g:") do
          case RuleMaven.Voices.get_def(voice, game) do
            %{vetted: false} -> RuleMaven.Workers.VoiceVetWorker.enqueue(game_id)
            _ -> :ok
          end
        end

        Jobs.event(
          run,
          :info,
          "Answering against the rulebook#{if expansion_ids != [], do: " (+#{length(expansion_ids)} expansion(s))", else: ""}…"
        )

        # Collapse concurrent identical asks onto one answer call. The lock has
        # to span the persist, not just `LLM.ask` — a follower woken before the
        # leader's row is written and `mark_pooled`'d would still see nothing
        # in the pool and pay for its own answer. `Singleflight` monitors the
        # leader, so a crash or `run_bounded` brutal-kill releases the key
        # instead of stranding followers.
        #
        # Keyed on the RAW question, since the normalized form only exists
        # inside `LLM.ask`. Literal duplicates (double-submit, two players
        # typing the same thing) collapse; concurrent paraphrases still race,
        # and are caught after the fact by the pool.
        #
        # A fresh ask (`skip_pool`) must neither wait on nor be served by
        # another asker's answer, so it bypasses the lock.
        sf_key =
          unless skip_pool do
            RuleMaven.LLM.Singleflight.ask_key(game_id, expansion_ids, question)
          end

        if sf_key, do: RuleMaven.LLM.Singleflight.acquire(sf_key)

        result =
          case run_bounded(fn ->
                 RuleMaven.LLM.ask(game, question, expansion_ids, recent_context,
                   user_id: user_id,
                   group_id: group_id,
                   skip_pool: skip_pool,
                   skip_normalize: skip_normalize,
                   voice: voice
                 )
               end) do
            {:ok, %{answer: raw_answer} = llm_result} ->
              {answer, error_kind} =
                cond do
                  is_nil(raw_answer) || String.trim(raw_answer) == "" ->
                    {"⚠️ The AI returned an empty response. Please retry.", "empty"}

                  suspicious_output?(raw_answer) ->
                    {"⚠️ The AI returned an unexpected response format. Please retry.", "format"}

                  true ->
                    stripped = strip_question_echo(raw_answer, question)
                    {if(String.trim(stripped) == "", do: raw_answer, else: stripped), nil}
                end

              ql = get_question_log!(question_log_id)
              source_id = llm_result[:source_question_log_id]

              # Answer-side dedup: a fresh answer (not a cache hit) that is identical
              # to one of the asker's own prior answers — two differently-worded
              # questions that produced the same ruling. Redirect there instead of
              # persisting a duplicate. Own rows only, so no cross-user exposure.
              # Skipped for error answers (the ⚠️ boilerplate is byte-identical
              # across unrelated failed questions — matching it would delete the
              # new question and redirect to an unrelated failure) and for short
              # answers ("Yes." to two different questions is not a duplicate).
              answer_dup =
                ql && !llm_result[:pool_hit] && !refused?(answer) && is_nil(error_kind) &&
                  String.length(String.trim(answer)) >= 20 &&
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
                     %{
                       question_log_id: question_log_id,
                       source_question_log_id: source_id,
                       asked_as: question
                     }}
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
                     %{
                       question_log_id: question_log_id,
                       source_question_log_id: answer_dup.id,
                       asked_as: question
                     }}
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
                    List.first(valid_citations) ||
                      %{"quote" => nil, "page" => nil, "source" => nil}

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
                  # Judged on its own length only — gating on the ANSWER's
                  # length discarded perfectly good cleaned questions whenever
                  # the answer happened to be short ("Yes, always.").
                  cleaned =
                    if cleaned != "" and String.length(cleaned) <= 250 do
                      cleaned
                    else
                      ""
                    end

                  update_attrs = %{
                    answer: answer,
                    error_kind: error_kind,
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
                    question_embedding: llm_result[:question_embedding],
                    # A group row's question text is unbrowsable until
                    # PublishCheckWorker clears it. A non-group row is browsable, as
                    # it always has been. `group_id` folds in the ROW's column, so a
                    # re-queue with no "group_id" arg can't publish a group row.
                    #
                    # `and ql.browsable` — this worker may only ever NARROW the flag,
                    # never widen it. The insert already decided publishability with
                    # context this worker does not have: a verbatim re-ask carries the
                    # crew's RAW text into a row whose group_id could not be carried
                    # across (the asker left the crew), and `retract_contributions/1`
                    # closes rows whose group_id is then nilified. In both cases
                    # `is_nil(group_id)` is true here, and an unconditional write
                    # would re-open the row the moment the answer landed — silently
                    # undoing the insert-time gate and every retraction.
                    browsable: is_nil(group_id) and ql.browsable,
                    # Recorded from the normalize step itself, not re-derived from
                    # the text afterwards. `skip_normalize` never normalizes, so
                    # this is false on that path by construction.
                    question_normalized: not skip_normalize and llm_result[:normalized] == true
                  }

                  case Games.log_question_update(ql, update_attrs) do
                    {:ok, updated} ->
                      pool_hit? = llm_result[:pool_hit] || false

                      if error_kind, do: maybe_auto_flag(updated, run)

                      unless refused? or error_kind do
                        RuleMaven.Workers.TagQuestionWorker.enqueue(question_log_id, game_id)

                        # Fresh, citation-backed answers become cache-eligible. Pool hits
                        # are duplicates of an existing pooled row — don't re-pool them.
                        # `never_pool` is set for a private one-off (regenerate/report
                        # redo of an already-voted answer) that must never leak into the
                        # shared pool. And a topic still under moderation review must not
                        # silently re-pool via the very next ask that happens to match it
                        # — that would undo the pull with zero review of the replacement.
                        # `never_pool` was computed at the TOP of this job, before an
                        # ask that can run for 180 seconds. Consent is not a constant
                        # over that window: `retract_contributions/1` (contribute-off,
                        # group delete, sole-owner account deletion) can land inside
                        # it, and it clears exactly the flags this block is about to
                        # re-set. The retraction was simply undone — `mark_pooled/1`
                        # put the answer back in the commons and the publish check,
                        # which only ever looked at `pooled`, then published the text.
                        #
                        # So ask again, now: the row's own retraction stamp, plus the
                        # group's LIVE contribute flag (re-resolved through the row, so
                        # a group deleted mid-ask reads as gone rather than as the
                        # stale id captured at line 41).
                        unless pool_hit? or never_pool or consent_withdrawn?(question_log_id) or
                                 unscrubbed_crew_row?(group_id, skip_normalize, updated) do
                          if Games.under_review?(
                               game_id,
                               expansion_ids,
                               updated.question_embedding
                             ) do
                            :ok
                          else
                            if group_id do
                              # A CREW row does not enter the pool here. It enters the
                              # pool by CLEARING THE SCREEN, and not before.
                              #
                              # This used to `mark_pooled` inline and enqueue the check
                              # afterwards — pool first, revoke later. That inverts the
                              # invariant. It left the answer serving every stranger
                              # during the queue hop, and if the check job was discarded
                              # (an LLM outage burns its 3 attempts), the answer served
                              # the commons FOREVER, never having been screened. The
                              # moduledoc's promise that an outage degrades to "crew
                              # questions don't get listed" was true of `browsable` and
                              # false of `pooled` — and `pooled` is the artifact that
                              # actually leaves the crew.
                              #
                              # `skip_normalize` rows are excluded outright: their text
                              # never passed the scrub, so there is nothing to screen and
                              # nothing that may publish.
                              #
                              # The crew is not deprived of its own answer: the
                              # `active_group_id` branch of `find_pool_candidates/3`
                              # requires `citation_valid`, NOT `pooled`.
                              if updated.citation_valid and not skip_normalize do
                                RuleMaven.Workers.PublishCheckWorker.enqueue(question_log_id)
                              end
                            else
                              # An ordinary personal row pools as it always has.
                              Games.mark_pooled(updated)
                            end
                          end
                        end
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
                        case RuleMaven.Voices.store_direct(
                               question_log_id,
                               styled_voice,
                               styled_answer
                             ) do
                          :ok ->
                            :ok

                          {:error, reason} ->
                            require Logger

                            Logger.warning(
                              "AskWorker: failed to cache styled answer for question #{question_log_id} voice #{styled_voice}: #{inspect(reason)}"
                            )
                        end
                      end

                      # Voices the single-call path can't cover — generated (g:)
                      # personas (whose LLM-derived style string must not enter the
                      # rulebook-access ask prompt — see LLM.voice_style_block/2)
                      # and pool hits (no fresh ask call at all) — are deliberately
                      # NOT restyled here: an inline restyle held the finished
                      # answer hostage behind a second ~20s LLM call. Broadcast the
                      # canonical answer immediately instead; the LiveView's
                      # :ask_complete handler (apply_default_voice) enqueues the
                      # on-demand VoiceWorker restyle, renders the plain answer
                      # with a "voicing…" indicator meanwhile, and swaps the
                      # persona text in on {:voice_ready, ...}.
                      {bcast_styled_voice, bcast_styled_answer} =
                        if store_direct?, do: {styled_voice, styled_answer}, else: {nil, nil}

                      broadcast_complete(updated, %{
                        faq_hit: llm_result[:faq_hit] || false,
                        pool_hit: pool_hit?,
                        tier: llm_result[:tier],
                        verified: llm_result[:verified] || false,
                        source_question_log_id: llm_result[:source_question_log_id],
                        followups: if(refused?, do: [], else: llm_result[:followups] || []),
                        cited_page: cited_page,
                        refused: refused?,
                        verdict: if(refused?, do: "silent", else: llm_result[:verdict]),
                        # Only ever carry a styled answer that was actually cached
                        # above (store_direct or inline restyle) — a refused
                        # question must not broadcast a styled answer even if the
                        # model ignored the "don't style a refusal" framing.
                        styled_voice: bcast_styled_voice,
                        styled_answer: bcast_styled_answer
                      })

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
                         %{question_log_id: question_log_id, error: "Failed to save answer"}}
                      )

                      Jobs.finish_run(run, "failed", "Failed to save answer.")
                  end
              end

              :ok

            {:error, reason} ->
              require Logger
              Logger.error("AskWorker failed for game #{game_id}: #{reason}")

              {friendly, error_kind} =
                cond do
                  is_binary(reason) && String.contains?(reason, "timeout") ->
                    {"⚠️ The AI took too long to respond. Please retry.", "timeout"}

                  is_binary(reason) && String.contains?(reason, "rate") ->
                    {"⚠️ Too many requests — please wait a moment and retry.", "rate_limited"}

                  is_binary(reason) && String.contains?(reason, "context") ->
                    {"⚠️ Question too long for the AI to process. Try a shorter question.",
                     "too_long"}

                  # Deliberately NOT retryable. A retry re-arms a fresh call
                  # budget, so classifying this as a generic transient error let
                  # one degenerate question spend its ceiling once per allowed
                  # retry — turning a per-ask cap into a per-attempt one. Fail
                  # loudly instead; it also auto-flags for moderation.
                  is_binary(reason) && String.contains?(reason, "call budget") ->
                    {"⚠️ This question needed too many attempts to answer reliably. Try rephrasing it.",
                     "budget"}

                  true ->
                    {"⚠️ Something went wrong. Please retry.", "unknown"}
                end

              if ql = get_question_log!(question_log_id) do
                case Games.log_question_update(ql, %{answer: friendly, error_kind: error_kind}) do
                  {:ok, updated} ->
                    maybe_auto_flag(updated, run)

                    Phoenix.PubSub.broadcast(
                      RuleMaven.PubSub,
                      "game:#{game_id}",
                      {:ask_error, %{question_log_id: question_log_id, error: reason}}
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

        if sf_key, do: RuleMaven.LLM.Singleflight.release(sf_key)
        result
    end
  end

  # Runs `fun` under a hard wall-clock cap (same idiom as
  # RulebookDownloader.cmd/4 for wedged binaries). Its return value passes
  # through unchanged; if it overruns, the task is killed and a timeout error
  # is returned — the word "timeout" routes it through the {:error, reason}
  # branch's classification, so the question row is flipped to a retryable
  # ⚠️ answer instead of hanging on "Thinking..." forever. Logger.metadata is
  # copied into the task so llm_logs rows written inside it still tag the
  # question (LLM.current_question_log_id/0 reads that metadata).
  def run_bounded(fun, timeout_ms \\ @ask_hard_timeout_ms) do
    md = Logger.metadata()

    task =
      Task.async(fn ->
        Logger.metadata(md)
        fun.()
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "ask exceeded #{timeout_ms}ms timeout"}
    end
  end

  # Persists a friendly "paused" answer and closes the run without ever calling
  # the LLM — mirrors the {:error, reason} terminal branch below (friendly
  # answer + :ask_error broadcast + finish_run), so the LiveView unblocks the
  # "Thinking..." row the same way a failed ask would.
  defp handle_disabled(run, game_id, question_log_id, _question) do
    # ⚠️-prefix so the row picks up the standard error styling (every error
    # check in the LiveView keys off that prefix); error_kind "paused" keeps
    # the retry button away — retrying while the switch is on is pointless.
    message = "⚠️ " <> RuleMaven.Settings.asks_disabled_message()

    if ql = get_question_log!(question_log_id) do
      case Games.log_question_update(ql, %{answer: message, error_kind: "paused"}) do
        {:ok, _updated} ->
          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            "game:#{game_id}",
            {:ask_error, %{question_log_id: question_log_id, error: message}}
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

  # Single choke point for the :ask_complete broadcast. `group_id` rides in
  # from the persisted row so Task 11's live feed panel can tell whether to
  # re-query the group feed — the topic is public to every viewer of the
  # game, so ONLY routing fields go on the wire, never group question content.
  # `also_asked` and `raw_response` are the asker's verbatim prose; the handler
  # re-reads them from the row through owner-scoped gates (`own_also_asked/2`,
  # `own_raw_response/2`), so they must not travel in the payload at all — a
  # subscriber that forgot to re-gate would otherwise render them.
  def broadcast_complete(%QuestionLog{} = ql, meta) do
    payload =
      meta
      |> Map.put(:question_log_id, ql.id)
      |> Map.put(:group_id, ql.group_id)

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, "game:#{ql.game_id}", {:ask_complete, payload})
  end

  # True once the row carries a real answer. The in-flight sentinel and a
  # vanished row both read as "not answered" — a deleted row is handled by the
  # `is_nil(ql)` branch further down, and a stuck "Thinking..." row is exactly
  # what a retry is meant to re-drive.
  defp answered_already?(question_log_id) do
    case get_question_log!(question_log_id) do
      nil -> false
      %{answer: answer} -> is_binary(answer) and String.trim(answer) not in ["", "Thinking..."]
    end
  end

  # Duplicate-execution path: the answer is already in the DB but the first
  # run may have died before telling the LiveView. Rebuild a minimal
  # :ask_complete from the persisted row; the handler re-reads the row for
  # everything it renders, so the payload only needs the routing fields.
  defp rebroadcast_completed(game_id, question_log_id) do
    if ql = get_question_log!(question_log_id) do
      # `answered_already?` treats a persisted ⚠️ row as "answered", so the
      # duplicate-execution path can land here holding an ERROR row. Replaying
      # it as :ask_complete would run the LiveView's success path over error
      # boilerplate: a paid VoiceWorker restyle of "⚠️ Please retry." (the
      # voice filter skips only `refused` rows, and error rows are not refused)
      # and possibly the answer-anatomy tour. Route it as the error it is.
      if failed_row?(ql) do
        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          # No raw `question` in the payload: `game:<id>` is a public topic and
          # the handler never read it anyway.
          {:ask_error, %{question_log_id: question_log_id, error: ql.answer}}
        )
      else
        broadcast_complete(ql, %{
          faq_hit: false,
          pool_hit: false,
          tier: nil,
          verified: ql.verified || false,
          source_question_log_id: ql.pool_source_id,
          followups: ql.followups || [],
          cited_page: ql.cited_page,
          refused: ql.refused,
          verdict: ql.verdict,
          styled_voice: nil,
          styled_answer: nil
        })
      end
    end

    :ok
  end

  defp failed_row?(ql) do
    not is_nil(ql.error_kind) or
      (is_binary(ql.answer) and String.starts_with?(ql.answer, "⚠️"))
  end

  # Mirrors handle_disabled/4: persist a friendly ⚠️ answer so the LiveView
  # unblocks the "Thinking..." row, and close the run without spending.
  defp handle_taken_down(run, game_id, question_log_id, _question) do
    message = "⚠️ This game is unavailable."

    if ql = get_question_log!(question_log_id) do
      case Games.log_question_update(ql, %{answer: message, error_kind: "paused"}) do
        {:ok, _updated} ->
          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            "game:#{game_id}",
            {:ask_error, %{question_log_id: question_log_id, error: message}}
          )

        {:error, changeset} ->
          Logger.error(
            "AskWorker takedown DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
          )
      end
    end

    Jobs.finish_run(run, "done", "Skipped — game is taken down.")
    :ok
  end

  # Retries exhausted and the answer still failed: file a system report into
  # the moderation queue so an admin sees the persistent failure without the
  # asker having to do anything. Games.auto_flag_error no-ops unless the row
  # really is out of retries, so this is safe to call on every error persist.
  defp maybe_auto_flag(question_log, run) do
    case Games.auto_flag_error(question_log) do
      {:ok, _flag} ->
        Jobs.event(run, :warn, "Retries exhausted — auto-reported to moderation.")

      :noop ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "AskWorker: auto-flag failed for question #{question_log.id}: #{inspect(reason)}"
        )
    end
  end

  # Short left-rail label: the question, truncated.
  # The label is written durably to job_runs and rendered in the admin Jobs panel
  # — a shared surface outside the group. A crew ask is labelled generically: the
  # raw wording has no business there, and nothing keys on the label.
  #
  # The second argument is crew PROVENANCE (`QuestionLog.crew_origin?`-shaped),
  # never a bare `group_id`: a crew row keeps its unscreened raw text after the
  # crew is deleted (group_id nilified), and keying on the live id would put that
  # text in the label for exactly those rows.
  defp ask_label(_question, true), do: "Ask (crew)"

  defp ask_label(question, _crew_origin?) when is_binary(question) do
    q = String.trim(question)
    if String.length(q) > 60, do: String.slice(q, 0, 57) <> "…", else: q
  end

  defp ask_label(_question, _crew_origin?), do: "Ask"

  defp get_question_log(id) do
    import Ecto.Query

    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  # The group the row itself belongs to, independent of the job args.
  defp row_group_id(id) do
    case get_question_log(id) do
      %QuestionLog{group_id: gid} -> gid
      _ -> nil
    end
  end

  # Defaults TRUE for a missing row: a brand-new ask is browsable unless its
  # insert said otherwise, and only a row that actually exists can be withdrawn.
  defp row_browsable?(id) do
    case get_question_log(id) do
      %QuestionLog{browsable: browsable} -> browsable
      _ -> true
    end
  end

  # The crew's ANSWER may feed the commons — that is the deal, and it is the ONE
  # artifact of a crew row that publishes by design. The premise underneath it is
  # that the answer contains no personal text. That premise rests entirely on the
  # NORMALIZE step, which is the thing that strips names ("Remove anything
  # personal: player names, proper nouns that are not game terms, and any narrative
  # about who did what" — the normalize prompt). The publish check screens the
  # QUESTION; nothing has ever screened the ANSWER.
  #
  # And the answer is generated from `match_text`, which is the RAW question
  # whenever normalize didn't run or didn't take:
  #
  #   * `skip_normalize` ("Ask exactly this") — LLM.ask sets cleaned = "" and
  #     match_text = the raw question, by design.
  #   * a normalize FALLBACK — any provider error, or a rewrite `accept_normalized?`
  #     rejects, returns the raw question.
  #
  # The answer prompt then does the rest: its ARGUMENT-SETTLING rule tells the model
  # to open with a verdict naming the disputing players — "(or the stated names)".
  # So "Dave says my rogue can sneak past; my brother Sam says no" comes back as
  # "⚖️ **Dave is right.**", gets pooled, and is served verbatim to the next
  # stranger who asks a similar rules question. The gate on the question text was
  # never the leak; the answer was.
  #
  # No scrub, no contribution. The crew keeps its own private cache either way —
  # the `active_group_id` branch of `find_pool_candidates/3` does not require
  # `pooled`, so the crew still gets its answer back; it just stays theirs.
  # Keyed on the RECORDED fact, not on a string comparison.
  #
  # The original version asked `String.trim(cleaned) == String.trim(question)` and
  # was a no-op in production: `strip_game_name/2` appends a "?" to the stored
  # `cleaned_question` when it doesn't end in one, so a normalize FALLBACK stores
  # "the raw question, plus a question mark" — never equal to the raw question. Any
  # crew member who typed a dispute without a trailing "?" (which is how people
  # type disputes) sailed straight through the guard on every provider hiccup.
  defp unscrubbed_crew_row?(nil, _skip_normalize, _row), do: false

  defp unscrubbed_crew_row?(_group_id, true, _row), do: true

  defp unscrubbed_crew_row?(_group_id, _skip_normalize, %QuestionLog{} = row) do
    cleaned = row.cleaned_question

    not row.question_normalized or not is_binary(cleaned) or String.trim(cleaned) == ""
  end

  # Durable withdrawal stamp. Unlike the browsable/pooled flags it cannot be
  # erased by the very pipeline it is meant to stop, and unlike `group_id` it
  # survives the group being deleted out from under the row.
  defp retracted?(id) do
    case get_question_log(id) do
      %QuestionLog{retracted_at: nil} -> false
      %QuestionLog{retracted_at: _} -> true
      _ -> false
    end
  end

  # Re-asked immediately before the row is pooled, against the CURRENT row and
  # the CURRENT group — not the snapshot taken before the LLM call. Resolving the
  # group through the row (rather than the `group_id` captured from the args) is
  # what makes a group deleted mid-ask read as withdrawn: the FK nilifies, and a
  # row that was a crew row but no longer resolves to a consenting crew has no
  # standing consent to pool on.
  defp consent_withdrawn?(id) do
    case get_question_log(id) do
      nil ->
        true

      %QuestionLog{retracted_at: stamp} when not is_nil(stamp) ->
        true

      %QuestionLog{group_id: nil} ->
        # Never a crew row (or its crew is gone and it was never retracted) —
        # an ordinary personal ask, which pools as it always has.
        false

      %QuestionLog{group_id: gid} ->
        not RuleMaven.Groups.contribute_to_community?(gid)
    end
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

  # Detect if LLM output looks encoded/transformed rather than plain English
  # prose. The shared detector also drives LLM.request_answer's automatic
  # retry, so an answer that trips this guard already survived one re-ask.
  defp suspicious_output?(text), do: RuleMaven.LLM.suspicious_answer?(text)

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
