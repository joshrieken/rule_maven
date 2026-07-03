defmodule RuleMaven.Workers.CleanupWorker do
  @moduledoc """
  Durable, restart-survivable rulebook text cleanup.

  Cleans each page's extracted text via the LLM and writes the result straight
  into `Document.pages[].cleaned` as it finishes, broadcasting per page so the
  LiveView swaps that page live. Because each finished page is persisted
  immediately, a server restart loses no completed work: Oban re-runs the
  orphaned job, and `perform/1` only processes pages whose `cleaned` is still
  nil — so it resumes exactly where it left off.

  `unique` keeps at most one active job per document, so a double-click or a
  remount can't spawn parallel cleaners racing on the same embeds_many column.
  """
  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 5,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}
  alias RuleMaven.Extract.Calibrate

  # LLM fan-out within a single job process; the writes back to the document are
  # funneled through Enum.each below, so they stay serialized (no embeds race).
  @max_concurrency 12

  @valid_levels ~w(auto light standard aggressive)

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: oban_id,
        args: %{"document_id" => doc_id, "game_id" => game_id} = args
      }) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{game_id}"
    level = parse_level(Map.get(args, "level"))
    mode = Map.get(args, "mode", "raw")
    page_index = Map.get(args, "page_index")

    label =
      if is_integer(page_index),
        do: "Clean page #{page_index + 1} — #{doc.label}",
        else: "Clean up — #{doc.label}"

    run = Jobs.start_run("cleanup", {"document", doc_id}, label, oban_job_id: oban_id)

    # Which pages to (re)clean and what text to feed the cleaner:
    #   page_index — a single-page clean (enqueue_cleanup_page/3): just that
    #             page, always from its original extraction, cleaned or not.
    #   "raw"   — a fresh clean from the original extraction. enqueue_cleanup/3
    #             nulled all `cleaned` first, so todo is every page (a resumed
    #             run skips pages a prior attempt already persisted).
    #   "again" — a second pass over the *current* cleaned text to scrub leftover
    #             junk. Cleaned text is kept (it's the input), so reprocess every
    #             page and feed its effective (cleaned||text) copy.
    todo =
      cond do
        is_integer(page_index) -> Enum.filter(doc.pages, &(&1.index == page_index))
        mode == "again" -> doc.pages
        true -> Enum.reject(doc.pages, &is_binary(&1.cleaned))
      end

    # A page run's progress counts against just its own page, not the book.
    total = if is_integer(page_index), do: length(todo), else: length(doc.pages)
    # Resume from the durable counter so a restart continues the count instead of
    # restarting it (capped at total for "again", which reprocesses every page).
    start_done = doc.cleaning_done || 0

    Jobs.event(run, "info", "Cleaning #{length(todo)} of #{total} pages (#{mode}, #{level})…")

    # Progress is funneled through this serial Enum.reduce (the async fan-out is
    # above), so the counter increments without races. Each step persists the
    # page, advances the durable counter, and broadcasts {done, total} — the
    # single source of truth for the UI, realtime and after a refresh.
    init = %{
      done: start_done,
      removed: 0,
      kept_raw: 0,
      unchanged: 0,
      cleaned: 0,
      failed: 0,
      flagged: 0,
      skipped: 0
    }

    stats =
      todo
      |> Task.async_stream(
        fn page ->
          {page.index, clean_one(page, level, mode, game_id, is_integer(page_index))}
        end,
        max_concurrency: @max_concurrency,
        ordered: false,
        timeout: :infinity,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.reduce(init, fn
        {:ok, {index, {:ok, cleaned, meta}}}, acc ->
          done = min(acc.done + 1, total)
          defects = meta[:defects] || []
          # Defects go onto the page itself (not just the job log) so the
          # Prepare page's ⚠ review UI (page_needs_review?) surfaces them.
          Games.set_page_cleaned(doc_id, index, cleaned, defects)
          Games.set_cleaning_done(doc_id, done)
          Jobs.event(run, event_level(meta.status), page_event_msg(index, meta, done, total))

          if defects != [] do
            Jobs.event(
              run,
              "warn",
              "Page #{index + 1} — cleanup review flagged #{length(defects)} issue(s): #{Enum.join(defects, " | ")}"
            )
          end

          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            topic,
            {:page_cleaned, doc_id, index, cleaned, done, total}
          )

          acc
          |> Map.put(:done, done)
          |> Map.update!(:removed, &(&1 + max(meta.in - meta.out, 0)))
          |> Map.update!(:flagged, &(&1 + if(defects == [], do: 0, else: 1)))
          |> Map.update(meta.status, 1, &(&1 + 1))

        # Skipped (vision-lane): no LLM call, no cleaned layer — effective text
        # falls back to the raw extraction, which is already model output.
        {:ok, {index, :skipped}}, acc ->
          done = min(acc.done + 1, total)
          Games.set_cleaning_done(doc_id, done)

          Jobs.event(
            run,
            "info",
            "Page #{index + 1} — skipped (vision-transcribed, already clean) · #{done}/#{total} done"
          )

          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            topic,
            {:page_cleaned, doc_id, index, nil, done, total}
          )

          acc |> Map.put(:done, done) |> Map.update(:skipped, 1, &(&1 + 1))

        # LLM failed for this page: leave `cleaned` nil rather than baking the raw
        # text in. Retrieval/display already fall back to `text` (effective text =
        # cleaned||text), and the page stays eligible for a later re-clean instead
        # of looking permanently "cleaned" after a transient blip. Don't advance
        # the counter — it reflects pages actually persisted.
        {:ok, {index, :failed}}, acc ->
          Jobs.event(
            run,
            "warn",
            "Page #{index + 1} failed to clean — left as-is, will retry on re-clean"
          )

          Map.update!(acc, :failed, &(&1 + 1))

        # A killed/exited task: same — leave it nil so a re-run retries it.
        {:exit, {page, _reason}}, acc ->
          Jobs.event(
            run,
            "warn",
            "Page #{page.index + 1} timed out/crashed — left as-is, will retry on re-clean"
          )

          Map.update!(acc, :failed, &(&1 + 1))
      end)

    # Re-chunk only when the doc already has chunks (a re-clean of a live doc)
    # so the cleaned text reaches retrieval instead of leaving stale raw-text
    # chunks. A first-run cleanup deliberately does NOT chunk — embedding is
    # the next pipeline step and is triggered explicitly (prepare page button
    # or the auto pipeline), never as a side effect of cleanup.
    doc = Games.get_document!(doc_id)
    rechunked? = Games.document_chunked?(doc_id)
    if rechunked?, do: Games.chunk_document(doc)
    # Re-render the "View as HTML" file from the freshly cleaned text.
    Games.regenerate_document_html(doc)
    Games.invalidate_pool(doc.game_id)
    # Derived content (suggestions/facts/setup/categories) is intentionally NOT
    # regenerated here — that's the explicit finalize step, run once the admin is
    # satisfied with the cleaned source.

    # Clear the durable counter now the run is finished (idle = nil).
    Games.set_cleaning_done(doc_id, nil)

    Jobs.finish_run(run, "done", finish_summary(stats, total, rechunked?))
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:cleanup_done, doc_id})
    :ok
  end

  alias RuleMaven.Extract.CleanCheck

  # Never let one page crash the job. Returns {:ok, cleaned, meta} on success or
  # :failed on any error — the caller leaves failed pages' `cleaned` nil so they
  # can be retried. `meta` carries in/out char counts, a status (:cleaned |
  # :unchanged | :kept_raw | :empty), the level `:path` taken, and `:defects`
  # (non-empty = page flagged for review).
  defp clean_one(page, level, mode, game_id, forced?) do
    if skippable_page?(page, level, forced?) and
         not Calibrate.should_sample?(skip_sample_rate()) do
      :skipped
    else
      body = if mode == "again", do: Games.effective_page_text(page), else: page.text || ""
      body = Games.strip_printed_number(body, page.printed)

      try do
        if level == :auto,
          do: clean_auto(body, page, game_id),
          else: clean_fixed(body, page, level, game_id)
      rescue
        _ -> :failed
      catch
        _, _ -> :failed
      end
    end
  end

  # Lanes whose text was produced by a vision-model transcription — already
  # LLM-shaped output, so a cleanup pass is a near-guaranteed no-op. Measured
  # on DungeonQuest post-column-fix: 7/12 pages "no changes", all vision-lane.
  @skip_lanes ~w(ensemble vision)
  # Same review threshold as Games.page_needs_review?/1 — below it the page is
  # already flagged for humans, so let cleanup have a look too.
  @skip_min_confidence 0.6

  @doc """
  Should this page skip the cleanup LLM call entirely? True only for auto-level
  bulk runs on confident vision-lane pages (their text already came out of a
  model — cleaning it again is paying to hear "no changes"). Forced runs
  (single-page re-clean) and explicit levels always clean. A drift sample of
  skippable pages is still cleaned by the caller to keep verifying this rule.
  """
  def skippable_page?(page, level, forced?) do
    not forced? and level == :auto and
      page.lane in @skip_lanes and
      is_number(page.confidence) and page.confidence >= @skip_min_confidence
  end

  # Fraction of skippable pages that get cleaned anyway, so "vision lane =
  # already clean" keeps being verified. Admin-tunable like the extract drift
  # rate; 0.0 disables sampling, 1.0 disables skipping.
  defp skip_sample_rate do
    case Float.parse(Settings.get("cleanup_skip_sample_rate") || "") do
      {r, _} when r >= 0.0 and r <= 1.0 -> r
      _ -> 0.1
    end
  end

  # Legacy single-shot path for explicit levels (mix tasks, queued jobs).
  defp clean_fixed(body, page, level, game_id) do
    case RuleMaven.LLM.cleanup_page(body, level, page.printed, game_id: game_id) do
      {:ok, text, status} ->
        {:ok, text, body |> clean_meta(status, text) |> Map.put(:defects, [])}

      {:error, _} ->
        :failed
    end
  end

  # The auto loop: clean at :standard, judge cheaply, retry once in the
  # direction the critic indicates, persist the best attempt. Per-page budget:
  # ≤2 clean calls + ≤2 critic calls, paid only by suspect pages.
  defp clean_auto(body, page, game_id) do
    case attempt(body, :standard, page, game_id) do
      :failed ->
        :failed

      {:ok, first} ->
        case judge(body, first, game_id) do
          {:accept, first} ->
            finish(body, first, [first])

          {:retry, next_level, first} ->
            case attempt(body, next_level, page, game_id) do
              # Retry call failed — fall back to the judged first attempt.
              :failed ->
                finish(body, first, [first])

              {:ok, second} ->
                case critic_verdict(body, second, game_id) do
                  {:ok, verdict} ->
                    second = %{second | verdict: verdict}
                    best = Enum.max_by([first, second], &rank/1)
                    finish(body, best, [first, second])

                  # Second attempt's critic call failed — it's unranked/unverified,
                  # so don't let it compete with the already-judged first attempt.
                  :error ->
                    finish(body, first, [first])
                end
            end
        end
    end
  end

  # One clean attempt at a concrete level. Soft guard: a below-floor output is
  # kept (:guard_fired) so the critic adjudicates instead of a blanket revert.
  defp attempt(body, level, page, game_id) do
    case RuleMaven.LLM.cleanup_page(body, level, page.printed,
           game_id: game_id,
           soft_guard: true
         ) do
      {:ok, text, status} ->
        # `cleanup_page` never returns :unchanged itself — reclassify here so
        # CleanCheck's :unchanged branch (junky input returned verbatim →
        # suspect) actually gets a chance to fire, mirroring clean_meta's logic.
        status =
          if status == :cleaned and String.trim(text) == String.trim(body),
            do: :unchanged,
            else: status

        {:ok, %{level: level, text: text, status: status, verdict: nil, defects: []}}

      {:error, _} ->
        :failed
    end
  end

  # Tier 1: free heuristics. Accept ends the page (no critic). Suspect pays one
  # critic call whose typed verdict picks the retry direction. Both outcomes
  # return the (possibly verdict-carrying) attempt so ranking/flagging can see
  # what the critic said.
  defp judge(body, att, game_id) do
    case CleanCheck.check(body, att.text, att.level, att.status) do
      :accept -> {:accept, att}
      {:suspect, _dir} -> accept_or_retry(body, att, game_id)
    end
  end

  defp accept_or_retry(body, att, game_id) do
    case critic_verdict(body, att, game_id) do
      {:ok, verdict} ->
        att = %{att | verdict: verdict}

        case verdict do
          %{verdict: :faithful} -> {:accept, att}
          %{verdict: :junk_remains} -> {:retry, :aggressive, att}
          %{verdict: :content_lost} -> {:retry, :light, att}
        end

      # Critic call itself failed (network/parse error, not a bad verdict). A
      # guard-fired attempt is a likely truncation with nothing else vouching
      # for it — revert to the raw page (legacy hard-guard behavior) rather
      # than silently persisting it. Any other suspect attempt is accepted
      # unverified: critic failure never blocks a cleanup.
      :error ->
        if att.status == :guard_fired do
          {:accept, %{att | text: body, status: :kept_raw, verdict: nil}}
        else
          {:accept, att}
        end
    end
  end

  # Returns `{:ok, verdict_map}` or `:error` — callers decide how to handle a
  # critic failure (never a silent "faithful", per the guard-fired hardening).
  defp critic_verdict(body, att, game_id) do
    case RuleMaven.LLM.critique_cleanup(body, att.text, game_id: game_id) do
      {:ok, verdict_map} -> {:ok, verdict_map}
      {:error, _} -> :error
    end
  end

  # Rank attempts: faithful beats any defect verdict; among equals, fewer
  # defects wins (Enum.max_by keeps the FIRST max on ties → the standard
  # attempt, the least surprising output).
  defp rank(%{verdict: nil}), do: {2, 0}
  defp rank(%{verdict: %{verdict: :faithful, defects: d}}), do: {2, -length(d)}
  defp rank(%{verdict: %{defects: d}}), do: {1, -length(d)}

  # Assemble the winning attempt's result. Defects flow into meta only when the
  # winner's verdict is still bad — that's what flags the page in the job log.
  defp finish(body, winner, attempts) do
    defects =
      case winner.verdict do
        %{verdict: v, defects: d} when v != :faithful -> d
        _ -> []
      end

    # :guard_fired means the critic accepted a legitimately short output — for
    # stats/log purposes that page was cleaned.
    status = if winner.status == :guard_fired, do: :cleaned, else: winner.status

    meta =
      body
      |> clean_meta(status, winner.text)
      |> Map.put(:defects, defects)
      |> Map.put(:path, Enum.map_join(attempts, "→", & &1.level))

    {:ok, winner.text, meta}
  end

  # Per-page result detail for the job log. A model that returned its input
  # essentially unchanged is reported as :unchanged (distinct from :kept_raw,
  # where the drop guard *rejected* a too-short output).
  defp clean_meta(body, status, text) do
    in_len = String.length(body)
    out_len = String.length(text)

    status =
      cond do
        status in [:kept_raw, :empty] -> status
        String.trim(text) == String.trim(body) -> :unchanged
        true -> :cleaned
      end

    %{status: status, in: in_len, out: out_len}
  end

  defp event_level(:kept_raw), do: "warn"
  defp event_level(_), do: "info"

  defp page_event_msg(index, %{status: :cleaned} = m, done, total) do
    path = if m[:path] && m.path != "standard", do: " (#{m.path})", else: ""

    "Cleaned page #{index + 1}#{path} — #{m.in}→#{m.out} chars (#{pct(m)}) · #{done}/#{total} done"
  end

  defp page_event_msg(index, %{status: :unchanged}, done, total),
    do: "Page #{index + 1} — no changes · #{done}/#{total} done"

  defp page_event_msg(index, %{status: :kept_raw}, done, total),
    do: "Page #{index + 1} — cleaner output too short, kept raw · #{done}/#{total} done"

  defp page_event_msg(index, %{status: :empty}, done, total),
    do: "Page #{index + 1} — blank, nothing to clean · #{done}/#{total} done"

  # Signed percent change in length, e.g. "−7%" / "+2%" / "0%".
  defp pct(%{in: 0}), do: "—"

  defp pct(%{in: i, out: o}) do
    p = round((o - i) / i * 100)
    sign = if p > 0, do: "+", else: if(p < 0, do: "−", else: "")
    "#{sign}#{abs(p)}%"
  end

  defp finish_summary(stats, total, rechunked?) do
    cleaned = Map.get(stats, :cleaned, 0)

    notes =
      [
        stats.removed > 0 && "removed #{stats.removed} chars",
        Map.get(stats, :unchanged, 0) > 0 && "#{stats.unchanged} unchanged",
        Map.get(stats, :skipped, 0) > 0 && "#{stats.skipped} skipped (vision lane)",
        Map.get(stats, :kept_raw, 0) > 0 && "#{stats.kept_raw} kept raw",
        Map.get(stats, :flagged, 0) > 0 && "#{stats.flagged} flagged for review",
        Map.get(stats, :failed, 0) > 0 && "#{stats.failed} failed"
      ]
      |> Enum.filter(& &1)

    base = "Cleaned #{cleaned}/#{total} pages" <> if rechunked?, do: " + re-chunked", else: ""
    if notes == [], do: base <> ".", else: base <> " (" <> Enum.join(notes, ", ") <> ")."
  end

  defp parse_level(level) when level in @valid_levels, do: String.to_existing_atom(level)
  defp parse_level(_), do: :auto
end
