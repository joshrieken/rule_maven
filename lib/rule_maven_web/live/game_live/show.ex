defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, CheatSheet}
  alias RuleMaven.Games.QuestionLog
  alias RuleMavenWeb.ReportModal
  alias Oban

  @max_concurrent 5

  @impl true
  def mount(_params, session, socket) do
    socket = maybe_curator_notice(socket)

    {:ok,
     assign(socket,
       is_admin: RuleMaven.Users.can?(socket.assigns.current_user, :admin),
       # Per-page-load seed (set by the :put_dyk_seed plug). Identical across the
       # dead render and the connected mount, so the "Did you know?" card picks
       # the same fact on both; re-rolls on a real refresh.
       dyk_seed: session["dyk_seed"] || :rand.uniform(1_000_000_000),
       game: nil,
       question: "",
       conversation: [],
       threads: [],
       active_thread_id: nil,
       pending_count: 0,
       pending: %{},
       max_concurrent: @max_concurrent,
       source_count: 0,
       retry_cooldowns: %{},
       confirm_delete_id: nil,
       suggestions: [],
       suggestions_open: true,
       suggestions_modal: false,
       sidebar_open: false,
       show_refused: false,
       community_vote_counts: %{},
       community_user_votes: %{},
       asker_confirmed_ids: MapSet.new(),
       flagged_ids: MapSet.new(),
       # Report-reason modal: nil, or %{id: local_answer_id, flag_target: source_id}
       report_target: nil,
       # Admin-only "version history" panel: which threads have it expanded,
       # and the lazily-fetched audit entries per thread id.
       history_open: MapSet.new(),
       question_history: %{},
       # Admin-only "LLM trace" panel: per-question llm_logs calls (op, model,
       # tokens, cost, duration) — same lazy toggle mechanics as history.
       llm_trace_open: MapSet.new(),
       llm_traces: %{},
       asks_disabled: false,
       included_expansions: %{},
       expansions_seeded: false,
       visibility: "private",
       search_query: "",
       community_questions: [],
       community_count: 0,
       favorited_answer_ids: MapSet.new(),
       refresh: 0,
       stale_timer: nil,
       question_categories: %{},
       # Persona voices: per-answer selected voice, lazily-loaded restyle cache
       # keyed by {question_log_id, voice}, and in-flight restyle requests.
       voice_sel: %{},
       voice_cache: %{},
       voice_pending: MapSet.new(),
       # {question_log_id, voice} restyles that failed — render falls back to the
       # plain answer for these instead of showing the loader forever.
       voice_failed: MapSet.new(),
       # In-flight streamed answer text per question_log_id ({:ask_partial, …}
       # broadcasts from the LLM SSE stream). Cleared on :ask_complete.
       ask_partial: %{},
       # Real pipeline stage per in-flight question ({:ask_stage, …} broadcasts
       # from LLM.ask) — drives the loader bar. Cleared with ask_partial.
       ask_stage: %{},
       # Voices available on this game: the built-in globals plus the game's own
       # generated, themed personas. Filled in once the game loads; updated live
       # by {:voices_ready} when generation finishes.
       voices: RuleMaven.Voices.all(),
       # User's preferred default voice, auto-selected on every answer. Seeded
       # from the localStorage connect param so it's known at the first connected
       # render — otherwise a fast (pool-hit) answer flashes plain before the
       # VoiceDefault hook's restore round-trips in. "neutral" means no auto-voice.
       default_voice: restore_default_voice(socket),
       rule_card: nil,
       # LLM-generated "Did you know?" facts (durable, per-game). Empty until the
       # worker fills them; the card falls back to a raw rulebook chunk meanwhile.
       dyk_facts: [],
       # Setup checklist (durable, per-game) + per-session checked items.
       setup_status: nil,
       setup_checklist: nil,
       checklist_done: MapSet.new(),
       # Deltas for the currently-included expansions that have one stored (see
       # `load_expansion_deltas/2`); empty until the connected mount fills it in.
       expansion_deltas: [],
       # House rules card: the user's own rules + the game's community list,
       # plus small per-session UI state (collapse, add-form, inline edit).
       house_rules: [],
       community_house_rules: [],
       hr_card_open: true,
       hr_form_open: false,
       hr_editing_id: nil,
       # Answer overlay (Tier 0/1): the user's own checked rules that embed
       # near the active thread's question, cached delta notes per rule, and
       # in-flight/failed delta requests. All keyed for the active thread only.
       hr_overlay: [],
       hr_overlay_deltas: %{},
       hr_delta_pending: MapSet.new(),
       hr_delta_failed: MapSet.new(),
       # Set on the first handle_params load; false until then.
       tour_autostart: false
     )}
  end

  # The per-browser default voice, read from the localStorage connect param so
  # it's already set at the connected mount. Left unvalidated here (the game
  # isn't loaded yet); apply_default_voice/2 coerces an unknown/stale voice to
  # neutral once handle_params has the game. Falls back to neutral on the dead
  # render and whenever nothing is saved.
  defp restore_default_voice(socket) do
    if connected?(socket) do
      case get_connect_params(socket) do
        %{"default_voice" => v} when is_binary(v) and v != "" -> v
        _ -> "neutral"
      end
    else
      "neutral"
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Games.get_game_by_token(params["id"]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That game doesn’t exist.")
         |> push_navigate(to: ~p"/")}

      game ->
        # DMCA takedown: non-admins can't reach a taken-down game at all. Admins
        # can still open it (to review / restore) and see a banner instead.
        if Games.taken_down?(game) and not socket.assigns.is_admin do
          throw_takedown(socket)
        else
          do_handle_params(params, game, socket)
        end
    end
  end

  defp throw_takedown(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This game has been removed.")
     |> push_navigate(to: ~p"/")}
  end

  defp do_handle_params(params, game, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.Setup.topic(game.id))

      Phoenix.PubSub.subscribe(
        RuleMaven.PubSub,
        RuleMaven.Workers.VoiceSuggestionsWorker.topic(game.id)
      )

      for exp <- Games.expansions_with_documents(game) do
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.ExpansionDelta.topic(exp.id))
      end
    end

    grouped = Games.grouped_questions(game, question_group_opts(socket))
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)

    # ?start=1 forces the start screen (suggested questions, setup checklist) —
    # no active thread. Otherwise prefer ?t=THREAD_ID, then socket assign, then
    # the first thread.
    active_thread_id =
      cond do
        params["start"] ->
          nil

        t = params["t"] ->
          case RuleMaven.Hashid.decode(t) do
            {:ok, tid} ->
              if Enum.any?(threads, &(&1.id == tid)), do: tid, else: select_active_thread(threads)

            :error ->
              select_active_thread(threads)
          end

        id = socket.assigns.active_thread_id ->
          if Enum.any?(threads, &(&1.id == id)), do: id, else: select_active_thread(threads)

        true ->
          select_active_thread(threads)
      end

    conversation = build_conversation_for_thread(grouped, active_thread_id)

    # Compute pending count from threads list
    pending_count = Enum.count(threads, & &1.pending)

    sources = Games.list_documents(game)
    expansions = Games.expansions_with_documents(game)

    # First load of this game: restore the user's remembered expansion set
    # (or default from their collection). Later handle_params runs (thread
    # nav, ?t=) keep the in-session toggles.
    seeded_before = socket.assigns.expansions_seeded

    included_expansions =
      if socket.assigns.expansions_seeded do
        socket.assigns.included_expansions
      else
        socket.assigns.current_user.id
        |> Games.effective_expansion_ids(game)
        |> Map.new(&{&1, true})
      end

    community = Games.community_questions(game, socket.assigns.current_user.id)
    community_count = RuleMaven.Faq.community_count(game)
    cq_ids = Enum.map(community, & &1.id)

    vote_ids =
      cq_ids ++ conversation_source_ids(conversation) ++ conversation_answer_ids(conversation)

    {cv_counts, cv_user, cv_asker} =
      Games.community_vote_maps(vote_ids, socket.assigns.current_user.id)

    favorited_answer_ids =
      Games.favorited_answer_ids(socket.assigns.current_user.id, Enum.uniq(vote_ids))

    all_thread_ids = Enum.map(threads, & &1.id)
    question_categories = Games.categories_for_questions(all_thread_ids ++ cq_ids)

    dyk_facts = load_did_you_know(game, sources, connected?(socket))
    {setup_status, setup_checklist} = load_setup(game, sources)

    socket =
      assign(socket,
        game: game,
        voices: RuleMaven.Voices.for_game(game),
        page_title: game.name,
        conversation: conversation,
        threads: threads,
        active_thread_id: active_thread_id,
        sources: sources,
        expansions: expansions,
        included_expansions: included_expansions,
        expansion_deltas: load_expansion_deltas(expansions, included_expansions),
        expansions_seeded: true,
        source_count: length(sources),
        question: "",
        pending_count: pending_count,
        pending: %{},
        community_questions: community,
        community_count: community_count,
        community_vote_counts: cv_counts,
        community_user_votes: cv_user,
        asker_confirmed_ids: cv_asker,
        favorited_answer_ids: favorited_answer_ids,
        flagged_ids: Games.user_flagged_ids(socket.assigns.current_user.id),
        asks_disabled: RuleMaven.Settings.asks_disabled?(),
        question_categories: question_categories,
        dyk_facts: dyk_facts,
        # Seed the pick with the per-load dyk_seed so the dead render and the
        # connected mount agree (no flicker, no layout shift) while a refresh
        # re-rolls it. Manual shuffle + new answers still randomize via fact_card/1.
        rule_card: dyk_card_for(dyk_facts, socket.assigns.dyk_seed),
        setup_status: setup_status,
        setup_checklist: setup_checklist,
        house_rules: load_own_house_rules(game, socket.assigns.current_user),
        community_house_rules:
          RuleMaven.HouseRules.community_for_game(game.id, socket.assigns.current_user.id)
      )

    # Restyle the just-loaded thread's answers to the current voice (switching
    # threads, ?t navigation, reload). No-op on first mount where the default is
    # still neutral — the VoiceDefault hook then fires default_voice_restore.
    socket = socket |> apply_default_voice(socket.assigns.default_voice) |> load_hr_overlay()

    # Onboarding: first-ever game page → the Tour hook auto-starts the tour
    # (via the data-tour-autostart attribute). Only computed on the initial
    # load of this mount (expansions_seeded gates first vs later handle_params).
    socket =
      if seeded_before,
        do: socket,
        else: assign(socket, :tour_autostart, RuleMavenWeb.Tours.autostart?(socket, "game"))

    suggestions =
      case RuleMaven.Settings.get("suggestions_#{game.id}") do
        nil ->
          # Generation is not automatic — it runs when an admin finalizes the
          # source. Subscribe so a finalize that happens while this page is open
          # streams the result in live; never enqueue here.
          if sources != [] and connected?(socket) do
            Phoenix.PubSub.subscribe(
              RuleMaven.PubSub,
              RuleMaven.Workers.SuggestionsWorker.topic(game.id)
            )
          end

          []

        json ->
          json
          |> Jason.decode!()
          |> Enum.map(fn %{"category" => c, "questions" => qs} ->
            %{category: c, questions: qs}
          end)
      end

    if pending_count > 0 do
      if socket.assigns.stale_timer, do: Process.cancel_timer(socket.assigns.stale_timer)

      timer = Process.send_after(self(), :check_stale, 120_000)

      {:noreply,
       assign(socket, suggestions: suggestions, suggestions_open: false, stale_timer: timer)}
    else
      if socket.assigns.stale_timer, do: Process.cancel_timer(socket.assigns.stale_timer)

      {:noreply,
       assign(socket, suggestions: suggestions, suggestions_open: false, stale_timer: nil)}
    end
  end

  # Pick the first non-refused thread, or the first thread, or nil.
  defp select_active_thread([]), do: nil

  defp select_active_thread(threads) do
    (Enum.find(threads, &(!&1.refused)) || List.first(threads)).id
  end

  # Build thread summary list from grouped questions (one per root).
  defp build_thread_summaries(grouped, current_user_id) do
    recent = DateTime.utc_now() |> DateTime.add(-120, :second)

    grouped
    |> Enum.map(fn g ->
      pending? =
        g.primary.answer == "Thinking..." &&
          not is_nil(g.primary.inserted_at) &&
          DateTime.compare(g.primary.inserted_at, recent) == :gt

      %{
        id: g.primary.id,
        question: QuestionLog.display_question(g.primary),
        answer: g.primary.answer,
        pending: pending?,
        refused: g.primary.refused,
        favorited: g.primary.favorited,
        inserted_at: g.primary.inserted_at,
        asker: asker_label(g.primary, current_user_id)
      }
    end)
    |> Enum.sort_by(fn t -> {if(t.favorited, do: 0, else: 1), t.inserted_at} end, fn
      {fa, ta}, {fb, tb} -> fa < fb || (fa == fb && DateTime.compare(ta, tb) == :gt)
    end)
  end

  defp asker_label(%{user_id: uid}, uid), do: "You"

  defp asker_label(%{user: %RuleMaven.Users.User{username: username}}, _uid)
       when is_binary(username),
       do: username

  defp asker_label(_question, _current_user_id), do: "Unknown"

  defp question_group_opts(socket) do
    if socket.assigns.is_admin do
      [limit: nil]
    else
      [user_id: socket.assigns.current_user.id]
    end
  end

  # Build flat conversation for a single thread (root + regen history).
  defp build_conversation_for_thread(grouped, thread_id) do
    case Enum.find(grouped, &(&1.primary.id == thread_id)) do
      nil -> []
      g -> build_conversation([g])
    end
  end

  defp build_conversation(grouped) do
    grouped
    |> Enum.flat_map(fn g ->
      user_msg = %{
        id: g.primary.id,
        role: :user,
        content: QuestionLog.display_question(g.primary),
        cleaned_question: g.primary.cleaned_question,
        refused: g.primary.refused,
        timestamp: g.primary.inserted_at
      }

      assistant_msg = %{
        id: g.primary.id,
        role: :assistant,
        content: g.primary.answer,
        cited_passage: g.primary.cited_passage,
        cited_page: g.primary.cited_page,
        cited_source: g.primary.cited_source,
        citations: g.primary.citations,
        verdict: g.primary.verdict,
        llm_provider: g.primary.llm_provider,
        llm_model: g.primary.llm_model,
        verified: g.primary.verified,
        faq_hit: false,
        pool_hit: g.primary.llm_provider == "pool",
        pool_provisional: g.primary.llm_model == "cached-unverified",
        pool_source_id: g.primary.pool_source_id,
        visibility: g.primary.visibility,
        refused: g.primary.refused,
        feedback: g.primary.feedback,
        favorited: g.primary.favorited,
        raw_response: g.primary.raw_response,
        followups: g.primary.followups,
        also_asked: g.primary.also_asked,
        error_kind: g.primary.error_kind,
        error_retries: g.primary.error_retries,
        timestamp: g.primary.inserted_at
      }

      history_msgs =
        Enum.map(g.history, fn h ->
          %{
            id: h.id,
            role: :assistant,
            content: h.answer,
            cited_passage: h.cited_passage,
            cited_page: h.cited_page,
            cited_source: h.cited_source,
            citations: h.citations,
            verdict: h.verdict,
            llm_provider: h.llm_provider,
            llm_model: h.llm_model,
            verified: h.verified,
            refused: h.refused,
            raw_response: h.raw_response,
            followups: h.followups,
            also_asked: h.also_asked,
            timestamp: h.inserted_at,
            history: true
          }
        end)

      [user_msg, assistant_msg | history_msgs]
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> mark_pending_thinking()
  end

  # In-character thank-you for the active persona voice; empty payload (client
  # falls back to its generic pool) for neutral or a voice with no thanks lines.
  defp vote_thanks_payload(socket) do
    RuleMaven.Voices.vote_thanks(socket.assigns.default_voice, socket.assigns.game) || %{}
  end

  defp vote_error_message(:self_vote), do: "You can't downvote your own answer."
  defp vote_error_message(:not_votable), do: "This answer isn't open for voting."
  defp vote_error_message(_), do: "Couldn't record your vote."

  # Source rows behind pool hits in the current thread — so their vote
  # counts/state load alongside the community list.
  defp conversation_source_ids(conversation) do
    conversation
    |> Enum.filter(& &1[:pool_source_id])
    |> Enum.map(& &1[:pool_source_id])
    |> Enum.uniq()
  end

  # Set the default voice and pre-generate its restyle for every answer in the
  # open thread. Manual per-answer selections in `voice_sel` are left untouched;
  # the default only fills in answers the user hasn't overridden (via the display
  # fallback). Already-cached restyles are reused; uncached ones enqueue a job.
  defp apply_default_voice(socket, voice) do
    # Coerce an unknown/stale voice to neutral so the render never shows the
    # loader for a voice that will never resolve.
    valid_voice? = voice != "neutral" and RuleMaven.Voices.valid?(voice, socket.assigns.game)
    socket = assign(socket, default_voice: if(valid_voice?, do: voice, else: "neutral"))

    if not valid_voice? do
      socket
    else
      socket.assigns.conversation
      # Only restyle FINAL answers. Restyling the in-flight "Thinking..."
      # placeholder produces a garbage stub (the model restyles the placeholder
      # text), so skip pending / non-final rows — they get restyled on
      # :ask_complete once the real answer lands. Refused rows are skipped too:
      # VoiceWorker refuses to restyle them, so enqueueing would leave
      # voice_pending set forever (they render plain regardless).
      |> Enum.filter(
        &(&1[:role] == :assistant && &1[:id] && !&1[:pending] && !&1[:refused] &&
            &1[:content] != "Thinking...")
      )
      |> Enum.map(& &1[:id])
      |> Enum.uniq()
      |> Enum.reduce(socket, fn id, acc ->
        cond do
          Map.has_key?(acc.assigns.voice_cache, {id, voice}) ->
            acc

          MapSet.member?(acc.assigns.voice_pending, {id, voice}) ->
            acc

          cached = RuleMaven.Voices.get(id, voice) ->
            assign(acc,
              voice_cache: Map.put(acc.assigns.voice_cache, {id, voice}, cached)
            )

          true ->
            %{
              question_log_id: id,
              voice: voice,
              game_id: acc.assigns.game.id,
              user_id: acc.assigns.current_user.id
            }
            |> RuleMaven.Workers.VoiceWorker.new()
            |> Oban.insert()

            assign(acc,
              voice_pending: MapSet.put(acc.assigns.voice_pending, {id, voice}),
              voice_failed: MapSet.delete(acc.assigns.voice_failed, {id, voice})
            )
        end
      end)
    end
  end

  # Own (non-pool) answer rows in the current thread. Other players who are
  # later served this answer from the pool vote on this same row, so loading
  # its counts lets the author see the community tally on their own answer.
  defp conversation_answer_ids(conversation) do
    conversation
    |> Enum.filter(&(&1[:role] == :assistant && &1[:id] && !&1[:pool_hit]))
    |> Enum.map(& &1[:id])
    |> Enum.uniq()
  end

  defp mark_pending_thinking(messages) do
    recent = DateTime.utc_now() |> DateTime.add(-120, :second)

    Enum.map(messages, fn
      %{role: :assistant, content: "Thinking...", timestamp: ts} = msg
      when not is_nil(ts) ->
        if DateTime.compare(ts, recent) == :gt do
          Map.put(msg, :pending, true)
        else
          # Stale: never got an answer; show error immediately on load
          %{msg | content: "⚠️ This question timed out. You can retry it."}
        end

      msg ->
        msg
    end)
  end

  @impl true
  def handle_event("tour_" <> _ = event, params, socket),
    do: RuleMavenWeb.Tours.handle_event(event, params, socket)

  def handle_event("toggle_expansion", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    included = socket.assigns.included_expansions

    included =
      if included[id] do
        Map.delete(included, id)
      else
        Map.put(included, id, true)
      end

    Games.put_expansion_selection(
      socket.assigns.current_user.id,
      socket.assigns.game.id,
      Map.keys(included)
    )

    {:noreply,
     assign(socket,
       included_expansions: included,
       expansion_deltas: load_expansion_deltas(socket.assigns.expansions, included)
     )}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_refused", _params, socket) do
    {:noreply, assign(socket, show_refused: !socket.assigns.show_refused)}
  end

  def handle_event("shuffle_rule", _params, socket) do
    {:noreply, assign(socket, rule_card: fact_card(socket.assigns.dyk_facts))}
  end

  def handle_event("toggle_step", %{"key" => key}, socket) do
    done = socket.assigns.checklist_done

    done =
      if MapSet.member?(done, key),
        do: MapSet.delete(done, key),
        else: MapSet.put(done, key)

    {:noreply, socket |> assign(checklist_done: done) |> push_checklist_save(done)}
  end

  def handle_event("reset_checklist", _params, socket) do
    done = MapSet.new()
    {:noreply, socket |> assign(checklist_done: done) |> push_checklist_save(done)}
  end

  # Restore checked items from the browser's localStorage (pushed by the
  # ChecklistStore hook on connect). Persists per-browser, not per-account.
  def handle_event("checklist_restore", %{"keys" => keys}, socket) when is_list(keys) do
    {:noreply, assign(socket, checklist_done: MapSet.new(keys))}
  end

  def handle_event("checklist_restore", _params, socket), do: {:noreply, socket}

  # House rules card -----------------------------------------------------

  def handle_event("toggle_house_rules_card", _params, socket) do
    {:noreply, assign(socket, hr_card_open: !socket.assigns.hr_card_open)}
  end

  def handle_event("toggle_house_rule_form", _params, socket) do
    {:noreply, assign(socket, hr_form_open: !socket.assigns.hr_form_open)}
  end

  def handle_event("add_house_rule", %{"house_rule" => params}, socket) do
    %{game: game, current_user: user} = socket.assigns

    case RuleMaven.HouseRules.submit(user, game.id, params) do
      {:ok, _hr} ->
        {:noreply,
         socket
         |> assign(house_rules: load_own_house_rules(game, user), hr_form_open: false)
         |> put_flash(:info, "House rule added — checking it against the rulebook…")}

      {:error, :injection} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a house rule.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, changeset_error_text(cs))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("start_edit_house_rule", %{"id" => id}, socket) do
    id = to_integer(id)
    hr = get_house_rule(id)

    if hr && owner?(socket, hr) do
      {:noreply, assign(socket, hr_editing_id: id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_house_rule", _params, socket) do
    {:noreply, assign(socket, hr_editing_id: nil)}
  end

  def handle_event("edit_house_rule", %{"id" => id, "house_rule" => params}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr),
         {:ok, _} <-
           RuleMaven.HouseRules.update_and_recheck(socket.assigns.current_user, hr, params) do
      {:noreply, socket |> assign(hr_editing_id: nil) |> refresh_house_rules()}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, :injection} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a house rule.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that house rule.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_house_rule", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr) do
      {:ok, _} = RuleMaven.HouseRules.delete(hr)
    end

    {:noreply, refresh_house_rules(socket)}
  end

  def handle_event("toggle_house_rule_visibility", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr) do
      new_vis = if hr.visibility == "community", do: "private", else: "community"
      {:ok, _} = RuleMaven.HouseRules.update(hr, %{"visibility" => new_vis})
    end

    {:noreply, refresh_house_rules(socket)}
  end

  def handle_event("recheck_house_rule", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr),
         {:ok, _} <- RuleMaven.HouseRules.resubmit_check(socket.assigns.current_user, hr) do
      {:noreply, refresh_house_rules(socket)}
    else
      {:error, msg} when is_binary(msg) -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("block_house_rule", %{"id" => id}, socket) do
    if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
      if hr = get_house_rule(id) do
        {:ok, _} = RuleMaven.HouseRules.set_blocked(hr, !hr.blocked)
      end
    end

    {:noreply, refresh_house_rules(socket)}
  end

  # "How does my rule change this answer?" — cache hit renders instantly and
  # free; a miss checks quota and enqueues the durable delta worker, showing a
  # spinner until {:house_rule_delta, ...} arrives over PubSub.
  def handle_event("house_rule_delta", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         tid when not is_nil(tid) <- socket.assigns.active_thread_id,
         %{} = ql <- get_question_log_by_id(tid) do
      case RuleMaven.HouseRules.request_delta(socket.assigns.current_user, hr, ql) do
        {:ok, delta} ->
          {:noreply,
           assign(socket,
             hr_overlay_deltas: Map.put(socket.assigns.hr_overlay_deltas, hr.id, delta.delta)
           )}

        :pending ->
          {:noreply,
           assign(socket,
             hr_delta_pending: MapSet.put(socket.assigns.hr_delta_pending, hr.id),
             hr_delta_failed: MapSet.delete(socket.assigns.hr_delta_failed, hr.id)
           )}

        {:error, msg} when is_binary(msg) ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Switch one answer to a persona voice. Neutral and already-cached voices swap
  # instantly (no cost); an uncached voice enqueues a durable restyle job and
  # shows a spinner until {:voice_ready, ...} arrives over PubSub.
  # Picking a voice from an answer's dropdown selects ONE current voice for every
  # answer (new and existing), and persists it per-browser — same as "set as
  # default". Per-answer overrides are cleared so the choice can't be shadowed by
  # a stale selection on another answer.
  def handle_event("set_voice", %{"voice" => voice}, socket) do
    if not RuleMaven.Voices.valid?(voice, socket.assigns.game) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(voice_sel: %{})
       |> apply_default_voice(voice)
       |> push_event("save_default_voice", %{voice: voice})}
    end
  end

  # Choose a default voice, auto-applied to every answer. Persist it per-browser
  # (the VoiceDefault hook writes localStorage) and apply it to the open thread.
  def handle_event("set_default_voice", %{"voice" => voice}, socket) do
    if RuleMaven.Voices.valid?(voice, socket.assigns.game) do
      {:noreply,
       socket
       |> apply_default_voice(voice)
       |> push_event("save_default_voice", %{voice: voice})}
    else
      {:noreply, socket}
    end
  end

  # Restore the saved default voice pushed by the VoiceDefault hook on connect.
  def handle_event("default_voice_restore", %{"voice" => voice}, socket) do
    {:noreply, apply_default_voice(socket, voice)}
  end

  def handle_event("default_voice_restore", _params, socket), do: {:noreply, socket}

  def handle_event("community_vote", %{"id" => id_str, "vote" => value}, socket) do
    {id, _} = Integer.parse(id_str)
    uid = socket.assigns.current_user.id

    # A fresh up-vote (not removing an existing one) earns a fun thank-you toast.
    new_upvote? = value == "up" && Map.get(socket.assigns.community_user_votes, id) != "up"

    case Games.set_community_vote(id, uid, value, socket.assigns.is_admin) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, vote_error_message(reason))}

      _ ->
        vote_ids =
          Enum.map(socket.assigns.community_questions, & &1.id) ++
            conversation_source_ids(socket.assigns.conversation) ++
            conversation_answer_ids(socket.assigns.conversation)

        {cv_counts, cv_user, cv_asker} = Games.community_vote_maps(vote_ids, uid)

        socket =
          assign(socket,
            community_vote_counts: cv_counts,
            community_user_votes: cv_user,
            asker_confirmed_ids: cv_asker
          )

        {:noreply,
         if(new_upvote?,
           do: push_event(socket, "vote_thanks", vote_thanks_payload(socket)),
           else: socket
         )}
    end
  end

  # Opens the report-reason modal for an answer. The actual flag is written on
  # "submit_report" once the user has picked a reason.
  def handle_event("open_report", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    # `id` is the locally-visible answer. The flag (and any auto-pull) targets
    # the *source* row behind a pool hit so reports concentrate on the real
    # culprit, not each player's served copy.
    msg = Enum.find(socket.assigns.conversation, &(&1[:id] == id && &1.role == :assistant))
    flag_target = (msg && msg[:pool_source_id]) || id

    # Scope to this game so a forged id from another game can't be flagged here.
    if find_question_log(socket.assigns.game, flag_target) do
      {:noreply, assign(socket, report_target: %{id: id, flag_target: flag_target})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, report_target: nil)}

  def handle_event("submit_report", params, socket) do
    case socket.assigns.report_target do
      nil ->
        {:noreply, socket}

      %{id: id, flag_target: flag_target} ->
        socket
        |> assign(report_target: nil)
        |> do_report(id, flag_target, ReportModal.compose_reason(params))
    end
  end

  # Refusal "Report as miscategorized" keeps its one-click confirm — the reason
  # is implied by the button — and records a fixed reason for moderators.
  def handle_event("flag_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    msg = Enum.find(socket.assigns.conversation, &(&1[:id] == id && &1.role == :assistant))
    flag_target = (msg && msg[:pool_source_id]) || id

    if find_question_log(socket.assigns.game, flag_target) do
      do_report(socket, id, flag_target, "Wrongly marked as 'not covered'")
    else
      {:noreply, socket}
    end
  end

  def handle_event("pull_for_review", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user = socket.assigns.current_user
    game = socket.assigns.game

    # Like flag_question: target the *source* row behind a pool hit, scoped to
    # this game so a forged id from another game can't be pulled here.
    msg = Enum.find(socket.assigns.conversation, &(&1[:id] == id && &1.role == :assistant))
    target = (msg && msg[:pool_source_id]) || id

    if find_question_log(game, target) do
      case Games.pull_for_review(target, user) do
        {:ok, %{pulled: true}} ->
          {:noreply,
           put_flash(socket, :info, "Pulled from the pool — it's in the moderation queue.")}

        {:ok, %{pulled: false}} ->
          {:noreply, put_flash(socket, :info, "Already out of the pool, awaiting review.")}

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_thread", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    {:noreply,
     socket
     |> assign(active_thread_id: id, sidebar_open: false)
     |> push_patch(to: ~p"/games/#{socket.assigns.game}?t=#{RuleMaven.Hashid.encode(id)}")}
  end

  @impl true
  def handle_event("quick_ask", %{"question" => question}, socket) do
    handle_event("ask", %{"question" => question}, socket)
  end

  @max_question_length 600
  @min_question_length 3

  def handle_event("ask", %{"question" => question} = params, socket) do
    # Strip --- sequences so user input can't inject parser delimiters into LLM output
    question = question |> String.replace("---", "") |> String.trim()
    visibility = params["visibility"] || socket.assigns.visibility

    cond do
      Games.taken_down?(socket.assigns.game) ->
        {:noreply,
         put_flash(socket, :error, "This game has been removed and can't be asked about.")}

      not socket.assigns.game.playable and not socket.assigns.is_admin ->
        {:noreply, put_flash(socket, :error, "This game isn't ready yet — check back soon.")}

      RuleMaven.Settings.asks_disabled?() and not socket.assigns.is_admin ->
        {:noreply, put_flash(socket, :error, RuleMaven.Settings.asks_disabled_message())}

      String.length(question) < @min_question_length ->
        {:noreply, put_flash(socket, :error, "Please ask a complete question.")}

      String.length(question) > @max_question_length ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Question is too long (max #{@max_question_length} characters)."
         )}

      true ->
        if question != "" do
          convo = socket.assigns.conversation

          already =
            Enum.find(convo, fn m ->
              m.role == :user && String.downcase(m.content) == String.downcase(question)
            end)

          if already do
            {:noreply,
             socket
             |> assign(question: "")
             |> put_flash(:info, "This question was already asked — scroll up to see the answer.")}
          else
            # Cross-thread duplicate: the asker already has this exact question
            # answered in a DIFFERENT thread (e.g. clicking a "related question"
            # suggestion that happens to match an earlier answer). Catching it
            # here — before the provisional row/AskWorker job exist — jumps
            # straight to the existing answer with a single voice-restyle loader,
            # instead of a throwaway "Thinking..." loader that gets discarded when
            # AskWorker's own (later, semantic) duplicate check redirects anyway.
            cross_thread_dup =
              Games.find_user_exact_repeat(
                socket.assigns.game.id,
                socket.assigns.current_user.id,
                question,
                Map.keys(socket.assigns.included_expansions)
              )

            if cross_thread_dup do
              {:noreply,
               socket
               |> assign(question: "", active_thread_id: cross_thread_dup.id, sidebar_open: false)
               |> put_flash(:info, "You already asked this — here's your answer.")
               |> push_patch(
                 to:
                   ~p"/games/#{socket.assigns.game}?t=#{RuleMaven.Hashid.encode(cross_thread_dup.id)}"
               )}
            else
              if socket.assigns.pending_count >= @max_concurrent do
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Maximum #{@max_concurrent} concurrent questions. Please wait for one to finish."
                 )}
              else
                %{game: game, included_expansions: included} = socket.assigns
                expansion_ids = Map.keys(included)

                # `convo` is already scoped to the active thread (it's built
                # per-thread), so just drop in-flight "Thinking..." turns and
                # superseded regeneration history; keep the root + followup
                # turns in order. build_recent_pairs/1 takes the last two pairs.
                #
                # The old `m.id == active_thread_id` filter kept ONLY the root
                # pair — whose id equals the thread id — silently dropping every
                # followup, so a continued conversation lost its recent turns.
                recent =
                  convo
                  |> Enum.reject(&(&1[:pending] || &1[:history]))
                  |> build_recent_pairs()

                case Games.log_question_with_rate_limit(socket.assigns.current_user, %{
                       game_id: game.id,
                       question: question,
                       answer: "Thinking...",
                       user_id: socket.assigns.current_user.id,
                       visibility: visibility,
                       expansion_ids: Enum.sort(expansion_ids)
                     }) do
                  {:ok, question_log} ->
                    %{
                      game_id: game.id,
                      question_log_id: question_log.id,
                      question: question,
                      expansion_ids: expansion_ids,
                      recent_context: recent,
                      user_id: socket.assigns.current_user.id,
                      voice: socket.assigns.default_voice
                    }
                    |> RuleMaven.Workers.AskWorker.new()
                    |> Oban.insert()

                    {:noreply,
                     socket
                     |> assign(
                       question: "",
                       active_thread_id: question_log.id,
                       rule_card: fact_card(socket.assigns.dyk_facts),
                       pending_count: socket.assigns.pending_count + 1,
                       conversation: [
                         %{
                           id: question_log.id,
                           role: :user,
                           content: question,
                           timestamp: DateTime.utc_now()
                         },
                         %{
                           id: question_log.id,
                           role: :assistant,
                           content: "Thinking...",
                           pending: true,
                           timestamp: DateTime.utc_now()
                         }
                       ],
                       threads: [
                         %{
                           id: question_log.id,
                           question: question,
                           pending: true,
                           refused: false,
                           inserted_at: DateTime.utc_now()
                         }
                         | socket.assigns.threads
                       ],
                       community_questions:
                         Games.community_questions(game, socket.assigns.current_user.id)
                     )
                     |> push_patch(
                       to: ~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(question_log.id)}"
                     )
                     |> push_event("scroll_bottom", %{})}

                  {:error, reason} when is_binary(reason) ->
                    {:noreply, put_flash(socket, :error, reason)}

                  {:error, _changeset} ->
                    {:noreply, put_flash(socket, :error, "Failed to save question")}
                end
              end
            end
          end
        else
          {:noreply, socket}
        end
    end

    # cond true ->
  end

  @impl true
  def handle_event("delete_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  @impl true
  def handle_event("confirm_delete_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    # Only the author (or an admin) may delete a row. The delete button renders
    # only on the user's own threads, but LiveView events are forgeable, so the
    # ownership check has to happen on the server.
    uid = socket.assigns.current_user.id

    case find_question_log(game, id) do
      %{user_id: author_id} = q when author_id == uid ->
        Games.delete_question(q, socket.assigns.current_user)

      q when not is_nil(q) ->
        if RuleMaven.Users.can?(socket.assigns.current_user, :admin),
          do: Games.delete_question(q, socket.assigns.current_user)

      nil ->
        :ok
    end

    # Rebuild threads and conversation from DB
    grouped = Games.grouped_questions(game, question_group_opts(socket))
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)

    deleted_was_active = socket.assigns.active_thread_id == id
    pending_count = Enum.count(threads, & &1.pending)

    if deleted_was_active do
      {:noreply,
       assign(socket,
         threads: threads,
         conversation: [],
         active_thread_id: nil,
         pending_count: pending_count,
         confirm_delete_id: nil
       )
       |> push_patch(to: ~p"/games/#{game}")}
    else
      conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)

      {:noreply,
       assign(socket,
         conversation: conversation,
         threads: threads,
         pending_count: pending_count,
         confirm_delete_id: nil
       )}
    end
  end

  @impl true
  def handle_event("cancel_delete_question", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  @impl true
  def handle_event("toggle_question_visibility", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    # Promoting a row to community marks it unconditionally trusted and served
    # cross-user, so this is admin-only. The button is admin-gated in the
    # template, but LiveView events are forgeable, so re-check on the server.
    if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
      do_toggle_question_visibility(socket, game, id)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "")}
  end

  @impl true
  def handle_event("ask_suggestion", %{"q" => q}, socket) do
    if socket.assigns.pending_count >= @max_concurrent do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Maximum #{@max_concurrent} concurrent questions. Please wait for one to finish."
       )}
    else
      socket = assign(socket, suggestions_open: false, suggestions_modal: false)
      handle_event("ask", %{"question" => q}, socket)
    end
  end

  def handle_event("open_suggestions", _params, socket),
    do: {:noreply, assign(socket, suggestions_modal: true)}

  def handle_event("close_suggestions", _params, socket),
    do: {:noreply, assign(socket, suggestions_modal: false)}

  @impl true
  def handle_event("favorite_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    q = Enum.find(socket.assigns.conversation, &(&1.id == id))

    if q do
      case Games.toggle_favorite(get_question_log_by_id(id)) do
        {:ok, updated} ->
          conversation =
            Enum.map(socket.assigns.conversation, fn m ->
              if m.id == id, do: Map.put(m, :favorited, updated.favorited), else: m
            end)

          threads =
            Enum.map(socket.assigns.threads, fn t ->
              if t.id == id, do: %{t | favorited: updated.favorited}, else: t
            end)
            |> Enum.sort_by(fn t -> {if(t.favorited, do: 0, else: 1), t.inserted_at} end, fn
              {fa, ta}, {fb, tb} -> fa < fb || (fa == fb && DateTime.compare(ta, tb) == :gt)
            end)

          {:noreply, assign(socket, conversation: conversation, threads: threads)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("favorite_community_answer", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case Games.toggle_answer_favorite(socket.assigns.current_user.id, id) do
      {:ok, favorited?} ->
        ids =
          if favorited?,
            do: MapSet.put(socket.assigns.favorited_answer_ids, id),
            else: MapSet.delete(socket.assigns.favorited_answer_ids, id)

        {:noreply, assign(socket, favorited_answer_ids: ids)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("verify_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
      case find_question_log(game, id) do
        nil -> :ok
        q -> Games.toggle_verified(q)
      end
    end

    grouped = Games.grouped_questions(game, question_group_opts(socket))
    conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)

    {:noreply,
     assign(socket,
       conversation: conversation,
       threads: threads,
       pending_count: Enum.count(threads, & &1.pending)
     )}
  end

  # Admin-only version history: lazily fetches prior deleted versions of this
  # Q&A (chained through question-text variants — see Audit.question_history/2)
  # the first time a thread's history panel is opened, then just toggles.
  # Seeds the lookup with every text variant of the live row (raw + cleaned +
  # canonical), not just the displayed text: regenerated rows drift phrasing,
  # and any one of the variants may be the link back to a prior version.
  @impl true
  def handle_event("toggle_question_history", %{"id" => id_str, "question" => question}, socket) do
    {id, _} = Integer.parse(id_str)

    if socket.assigns.is_admin do
      open = socket.assigns.history_open

      if MapSet.member?(open, id) do
        {:noreply, assign(socket, history_open: MapSet.delete(open, id))}
      else
        history =
          Map.put_new_lazy(socket.assigns.question_history, id, fn ->
            seeds =
              case find_question_log(socket.assigns.game, id) do
                nil -> [question]
                ql -> [question, ql.question, ql.cleaned_question, ql.canonical_question]
              end

            RuleMaven.Audit.question_history(socket.assigns.game.id, seeds)
          end)

        {:noreply, assign(socket, history_open: MapSet.put(open, id), question_history: history)}
      end
    else
      {:noreply, socket}
    end
  end

  # Admin-only LLM trace: lazily fetches the llm_logs calls recorded for this
  # question the first time its panel is opened, then just toggles. A fresh
  # fetch happens once per LiveView mount — good enough, since the trace only
  # grows while the answer is still being produced.
  @impl true
  def handle_event("toggle_llm_trace", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    if socket.assigns.is_admin do
      open = socket.assigns.llm_trace_open

      if MapSet.member?(open, id) do
        {:noreply, assign(socket, llm_trace_open: MapSet.delete(open, id))}
      else
        traces =
          Map.put_new_lazy(socket.assigns.llm_traces, id, fn ->
            RuleMaven.LLM.calls_for_question(id)
          end)

        {:noreply, assign(socket, llm_trace_open: MapSet.put(open, id), llm_traces: traces)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    cooldowns = socket.assigns.retry_cooldowns
    now = System.system_time(:second)
    q = find_question_log(socket.assigns.game, id)

    # Rate-limit failures get a longer button cooldown — hammering retry right
    # after a provider 429 only extends the limit.
    cooldown = if q && q.error_kind == "rate_limited", do: 30, else: 10

    cond do
      Map.get(cooldowns, id, 0) + cooldown > now ->
        {:noreply, put_flash(socket, :error, "Please wait a moment before retrying.")}

      # Players may retry a failed answer (bounded kinds/count) or a stuck
      # "Thinking..." row; admins keep the unrestricted re-ask.
      socket.assigns.is_admin || is_nil(q) || q.answer == "Thinking..." ||
          Games.error_retryable?(q) ->
        resubmit_question(id, socket, skip_pool: false)

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("regenerate_answer", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    regen_fresh(id, socket)
  end

  @impl true
  def handle_event("not_my_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user = socket.assigns.current_user

    # "This answered a different question": the pool matcher served a cached
    # answer that doesn't fit what the asker meant. Bump the mismatch counter
    # on the matched row (a threshold-tuning signal — the answer itself stays
    # untouched for its own question), then re-ask with skip_pool: no cache
    # tier at all, so the fresh answer can't re-match the same wrong neighbor.
    q = find_question_log(socket.assigns.game, id)

    if user && q && q.user_id == user.id && q.llm_provider == "pool" do
      Games.record_pool_mismatch(q)
      regen_fresh(id, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("regenerate_html", %{"id" => id_str}, socket) do
    # Admin-only: re-render the source's "View as HTML" file from its current text.
    if socket.assigns.is_admin do
      with {id, _} <- Integer.parse(id_str),
           %Games.Document{} = doc <- Games.get_document(id),
           :ok <- Games.regenerate_document_html(doc) do
        {:noreply, put_flash(socket, :info, "Rulebook HTML regenerated.")}
      else
        _ -> {:noreply, put_flash(socket, :error, "Could not regenerate that rulebook.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  # Guards HouseRules.get/1 against a nil id (a non-numeric phx-value-id):
  # Repo.get/2 raises ArgumentError on a nil primary key, so a crafted
  # non-numeric id must short-circuit to nil rather than reach the repo.
  defp get_house_rule(nil), do: nil
  defp get_house_rule(id), do: id |> to_integer() |> get_house_rule_by_int()

  defp get_house_rule_by_int(nil), do: nil
  defp get_house_rule_by_int(int), do: RuleMaven.HouseRules.get(int)

  defp owner?(socket, hr) do
    u = socket.assigns.current_user
    u && u.id == hr.user_id
  end

  defp refresh_house_rules(socket) do
    %{game: game, current_user: user} = socket.assigns

    socket
    |> assign(
      house_rules: load_own_house_rules(game, user),
      community_house_rules: RuleMaven.HouseRules.community_for_game(game.id, user && user.id)
    )
    |> load_hr_overlay()
  end

  # Recompute the house-rule overlay for the active thread: pgvector match of
  # the user's checked rules against the question embedding (no LLM), plus any
  # already-cached delta notes. Runs on thread switch, answer completion, and
  # house-rule changes; each run resolves in-flight delta spinners that landed.
  defp load_hr_overlay(socket) do
    %{game: game, current_user: user, active_thread_id: tid} = socket.assigns

    with true <- user != nil,
         tid when not is_nil(tid) <- tid,
         %{} = ql <- get_question_log_by_id(tid),
         false <- ql.refused do
      rules = RuleMaven.HouseRules.overlay_rules(user.id, game.id, ql.question_embedding)

      deltas =
        for hr <- rules,
            d = RuleMaven.HouseRules.get_delta(hr, ql),
            into: %{},
            do: {hr.id, d.delta}

      assign(socket,
        hr_overlay: rules,
        hr_overlay_deltas: deltas,
        hr_delta_pending:
          MapSet.reject(socket.assigns.hr_delta_pending, &(&1 in Map.keys(deltas)))
      )
    else
      _ -> assign(socket, hr_overlay: [], hr_overlay_deltas: %{}, hr_delta_pending: MapSet.new())
    end
  end

  defp load_own_house_rules(_game, nil), do: []
  defp load_own_house_rules(game, user), do: RuleMaven.HouseRules.list_for_user(game.id, user.id)

  defp changeset_error_text(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp house_rule_stamp("matches"), do: {"✅", "Matches RAW"}
  defp house_rule_stamp("fills_gap"), do: {"🧩", "Fills a gap"}
  defp house_rule_stamp("overrides"), do: {"🔀", "Overrides RAW"}
  defp house_rule_stamp(_), do: {"🤔", "Unclear"}

  # Demote-only: promotion to community happens via vote quorum or admin
  # verify, never this toggle (events are forgeable, so the promote direction
  # is rejected server-side too, not just hidden in the template).
  defp do_toggle_question_visibility(socket, game, id) do
    case find_question_log(game, id) do
      nil ->
        {:noreply, socket}

      %{visibility: vis} when vis != "community" ->
        {:noreply, socket}

      q ->
        Games.update_question_visibility(q, "private")

        grouped = Games.grouped_questions(game, question_group_opts(socket))
        conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
        threads = build_thread_summaries(grouped, socket.assigns.current_user.id)
        community = Games.community_questions(game, socket.assigns.current_user.id)

        {:noreply,
         assign(socket,
           conversation: conversation,
           threads: threads,
           community_questions: community,
           pending_count: Enum.count(threads, & &1.pending),
           refresh: socket.assigns.refresh + 1
         )}
    end
  end

  defp do_report(socket, id, flag_target, reason) do
    case Games.report_answer(flag_target, socket.assigns.current_user, reason) do
      {:ok, %{pulled: pulled}} ->
        socket =
          socket
          |> assign(flagged_ids: MapSet.put(socket.assigns.flagged_ids, flag_target))
          |> put_flash(:info, report_flash(pulled))

        # Give the reporter a fresh, rulebook-grounded answer right away instead
        # of leaving them on the answer they just flagged. Gated: resubmit_question
        # runs check_rate_limit (quota + daily $ cap) and counts as one of their
        # asks, and a short cooldown blocks report→regen hammering — so this can't
        # be turned into free/unlimited generations.
        cooldowns = socket.assigns.retry_cooldowns
        now = System.system_time(:second)

        if Map.get(cooldowns, id, 0) + 10 <= now do
          resubmit_question(id, socket, skip_pool: true)
        else
          {:noreply, socket}
        end

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp report_flash(true),
    do: "Reported and pulled from the Community Q&A for review. Fetching you a fresh answer…"

  defp report_flash(false),
    do: "Reported — thanks. A moderator will take a look. Fetching you a fresh answer…"

  # Discard a provisional/cached answer and force a fresh rulebook-grounded one.
  # Reset this answer's voice back to plain — old restyles no longer apply.
  defp regen_fresh(id, socket) do
    socket =
      assign(socket,
        voice_sel: Map.delete(socket.assigns.voice_sel, id),
        voice_cache: Map.reject(socket.assigns.voice_cache, fn {{qid, _v}, _} -> qid == id end),
        voice_pending:
          socket.assigns.voice_pending
          |> Enum.reject(fn {qid, _v} -> qid == id end)
          |> MapSet.new()
      )

    resubmit_question(id, socket, skip_pool: true)
  end

  defp resubmit_question(id, socket, opts) do
    skip_pool = Keyword.get(opts, :skip_pool, false)
    cooldowns = socket.assigns.retry_cooldowns
    now = System.system_time(:second)

    question =
      socket.assigns.conversation
      |> Enum.find(&(&1.id == id && &1.role == :user))
      |> case do
        nil -> ""
        m -> m.content
      end

    cond do
      RuleMaven.Settings.asks_disabled?() and not socket.assigns.is_admin ->
        {:noreply, put_flash(socket, :error, RuleMaven.Settings.asks_disabled_message())}

      question == "" ->
        {:noreply, socket}

      true ->
        # The answer is about to change — drop any cached persona restyles.
        RuleMaven.Voices.clear_for_question(id)

        %{game: game, included_expansions: included} = socket.assigns
        expansion_ids = Map.keys(included)

        old_q = find_question_log(game, id)
        was_pending = old_q && old_q.answer == "Thinking..."

        # Resubmitting a failed (or stuck-"Thinking...") answer consumes one of
        # the question's bounded error retries; the count rides along to the
        # replacement row since the old one is deleted below. A resubmit of a
        # healthy answer (regenerate, report-redo) starts fresh at 0.
        carried_retries =
          if old_q && (Games.failed_answer?(old_q) || old_q.answer == "Thinking..."),
            do: old_q.error_retries + 1,
            else: 0

        # An answer that already has community votes is never solo-deleted:
        # doing so would cascade-wipe those votes and silently swap the
        # shared answer every other user sees, with no review. Instead, spin
        # off a private, never-pooled copy for just this user and leave the
        # existing (voted-on) row untouched for everyone else.
        protect_existing? = old_q && Games.has_votes?(old_q.id)

        if old_q && not protect_existing?, do: Games.delete_question(old_q)

        visibility =
          cond do
            protect_existing? -> "private"
            old_q -> old_q.visibility
            true -> "private"
          end

        now_dt = DateTime.utc_now()

        # Collect recent Q&A for followup context (from current visible conversation)
        remaining_convo =
          Enum.reject(socket.assigns.conversation, fn
            %{id: ^id} -> true
            _ -> false
          end)

        # Scope context to the retried thread only
        retried_tid = id

        recent =
          remaining_convo
          |> Enum.filter(fn m -> m.id == retried_tid end)
          |> Enum.reject(& &1[:pending])
          |> build_recent_pairs()

        case Games.log_question_with_rate_limit(socket.assigns.current_user, %{
               game_id: game.id,
               question: question,
               answer: "Thinking...",
               user_id: socket.assigns.current_user.id,
               visibility: visibility,
               expansion_ids: Enum.sort(expansion_ids),
               error_retries: carried_retries
             }) do
          {:ok, question_log} ->
            %{
              game_id: game.id,
              question_log_id: question_log.id,
              question: question,
              expansion_ids: expansion_ids,
              recent_context: recent,
              user_id: socket.assigns.current_user.id,
              skip_pool: skip_pool,
              never_pool: protect_existing?
            }
            |> RuleMaven.Workers.AskWorker.new()
            |> Oban.insert()

            # Build threads list — remove old thread, add new pending one
            threads =
              [
                %{
                  id: question_log.id,
                  question: question,
                  pending: true,
                  refused: false,
                  inserted_at: now_dt
                }
                | Enum.reject(socket.assigns.threads, &(&1.id == id))
              ]

            {:noreply,
             socket
             |> assign(
               conversation: [
                 %{id: question_log.id, role: :user, content: question, timestamp: now_dt},
                 %{
                   id: question_log.id,
                   role: :assistant,
                   content: "Thinking...",
                   pending: true,
                   timestamp: now_dt
                 }
               ],
               threads: threads,
               active_thread_id: question_log.id,
               question: "",
               pending_count:
                 if(was_pending,
                   do: socket.assigns.pending_count,
                   else: socket.assigns.pending_count + 1
                 ),
               retry_cooldowns: Map.put(cooldowns, id, now),
               community_questions:
                 Games.community_questions(game, socket.assigns.current_user.id)
             )
             |> push_patch(to: ~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(question_log.id)}")}

          {:error, reason} when is_binary(reason) ->
            {:noreply, put_flash(socket, :error, reason)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to retry question")}
        end
    end
  end

  # Scope the lookup to the current game so an id from another game can't be
  # acted on through this game-scoped LiveView (cross-game IDOR).
  defp find_question_log(game, id) do
    import Ecto.Query
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id and q.game_id == ^game.id)
  end

  defp get_question_log_by_id(id) do
    import Ecto.Query
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  defp matches_search?(_t, ""), do: true

  defp matches_search?(t, query) do
    q = String.downcase(query)

    String.contains?(String.downcase(t.question), q) ||
      (is_binary(t[:asker]) && String.contains?(String.downcase(t.asker), q))
  end

  defp group_threads_by_time(threads) do
    now = DateTime.utc_now()
    today_start = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    week_start = DateTime.add(today_start, -6, :day)

    Enum.group_by(threads, fn t ->
      dt =
        case t.inserted_at do
          %DateTime{} = d -> d
          %NaiveDateTime{} = d -> DateTime.from_naive!(d, "Etc/UTC")
          _ -> DateTime.add(now, -999, :day)
        end

      cond do
        DateTime.compare(dt, today_start) != :lt -> :today
        DateTime.compare(dt, week_start) != :lt -> :week
        true -> :older
      end
    end)
  end

  # Same-user duplicate: AskWorker deleted the provisional row and points us at
  # the asker's existing answer. Only the asker (whose threads hold the
  # provisional id) redirects; other viewers on this game topic ignore it.
  @impl true
  def handle_info(
        {:ask_redirect, %{question_log_id: prov_id, source_question_log_id: source_id}},
        socket
      ) do
    if Enum.any?(socket.assigns.threads, &(&1.id == prov_id)) do
      {:noreply,
       socket
       |> assign(
         active_thread_id: source_id,
         ask_partial: Map.delete(socket.assigns.ask_partial, prov_id),
         ask_stage: Map.delete(socket.assigns.ask_stage, prov_id)
       )
       |> put_flash(:info, "You already asked this — here's your answer.")
       |> push_patch(
         to: ~p"/games/#{socket.assigns.game}?t=#{RuleMaven.Hashid.encode(source_id)}"
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:ask_complete, data}, socket) do
    question_log_id = data.question_log_id
    game = socket.assigns.game

    ql = get_question_log_by_id(question_log_id)

    if ql do
      # Update thread status in threads list (only when answer is actually ready)
      threads =
        if ql.answer != "Thinking..." do
          updated =
            Enum.map(socket.assigns.threads, fn
              %{id: ^question_log_id} = t ->
                %{
                  t
                  | pending: false,
                    refused: ql.refused,
                    question: QuestionLog.display_question(ql),
                    answer: ql.answer
                }

              t ->
                t
            end)

          updated
        else
          socket.assigns.threads
        end

      # Targeted update if this thread is currently active
      conversation =
        if socket.assigns.active_thread_id == question_log_id do
          Enum.map(socket.assigns.conversation, fn
            %{id: ^question_log_id, role: :user} = msg ->
              msg
              |> Map.put(:content, QuestionLog.display_question(ql))
              |> Map.put(:cleaned_question, ql.cleaned_question)

            %{id: ^question_log_id, role: :assistant} = msg ->
              if ql.answer == "Thinking..." do
                msg
              else
                msg
                |> Map.delete(:pending)
                |> Map.put(:content, ql.answer)
                |> Map.put(:cited_passage, ql.cited_passage)
                |> Map.put(:cited_page, data[:cited_page] || ql.cited_page)
                |> Map.put(:cited_source, data[:cited_source] || ql.cited_source)
                |> Map.put(:citations, ql.citations)
                |> Map.put(:verdict, data[:verdict] || ql.verdict)
                |> Map.put(:followups, data[:followups] || ql.followups)
                |> Map.put(:also_asked, data[:also_asked] || ql.also_asked)
                |> Map.put(:refused, ql.refused)
                |> Map.put(:raw_response, ql.raw_response)
                |> Map.put(:llm_provider, ql.llm_provider)
                |> Map.put(:llm_model, ql.llm_model)
                |> Map.put(:pool_hit, ql.llm_provider == "pool")
                |> Map.put(:pool_provisional, ql.llm_model == "cached-unverified")
                |> Map.put(:pool_source_id, ql.pool_source_id)
                |> Map.put(:visibility, ql.visibility)
                |> Map.put(:error_kind, ql.error_kind)
                |> Map.put(:error_retries, ql.error_retries)
              end

            msg ->
              msg
          end)
        else
          socket.assigns.conversation
        end

      pending_count = Enum.count(threads, & &1.pending)

      community = Games.community_questions(game, socket.assigns.current_user.id)

      # When the real answer lands on the active thread, jump the reader to the
      # top of it so they start at the beginning; while still "Thinking..." just
      # keep the pending bubble in view at the bottom.
      answer_ready? =
        ql.answer != "Thinking..." && socket.assigns.active_thread_id == question_log_id

      socket =
        socket
        |> assign(
          conversation: conversation,
          threads: threads,
          pending_count: pending_count,
          community_questions: community,
          ask_partial: Map.delete(socket.assigns.ask_partial, question_log_id),
          ask_stage: Map.delete(socket.assigns.ask_stage, question_log_id),
          refresh: socket.assigns.refresh + 1
        )

      # Persona-direct path (Task 5): the ask call already produced the styled
      # answer in the same LLM response, so populate voice_cache straight from
      # the broadcast — apply_default_voice/2 below already skips re-enqueuing
      # a VoiceWorker restyle for a voice already present in voice_cache.
      socket =
        if data[:styled_answer] && data[:styled_voice] do
          assign(socket,
            voice_cache:
              Map.put(
                socket.assigns.voice_cache,
                {question_log_id, data[:styled_voice]},
                data[:styled_answer]
              )
          )
        else
          socket
        end

      # A freshly-answered row inherits the current voice: restyle it to the
      # active default so it doesn't show plain while every other answer is in
      # character. No-op when the default is neutral.
      socket =
        if ql.answer != "Thinking...",
          do: apply_default_voice(socket, socket.assigns.default_voice),
          else: socket

      # The answered question now has an embedding — surface any of the user's
      # house rules that sit near it.
      socket = if answer_ready?, do: load_hr_overlay(socket), else: socket

      # First real answer this user has ever seen: walk them through its
      # anatomy (verdict, confidence, citations, voting → curator points).
      # The live answer is the tour's demo data, so it never runs on an empty
      # page; tour_done marks it seen and it stops auto-starting.
      socket =
        if answer_ready? and not ql.refused and
             RuleMavenWeb.Tours.autostart?(socket, "answer"),
           do: RuleMavenWeb.Tours.push_tour(socket, "answer"),
           else: socket

      # No scroll when the answer finishes — the reader is already at the top of
      # the answer (or wherever they scrolled to) and shouldn't be yanked down.
      {:noreply,
       if(answer_ready?,
         do: socket,
         else: push_event(socket, "scroll_bottom", %{})
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:question_tagged, ql_id}, socket) do
    cats = Games.categories_for_questions([ql_id])
    merged = Map.merge(socket.assigns.question_categories, cats)
    {:noreply, assign(socket, question_categories: merged, refresh: socket.assigns.refresh + 1)}
  end

  def handle_info({:setup_done, game_id}, socket) do
    if socket.assigns.game && socket.assigns.game.id == game_id do
      {:noreply,
       assign(socket,
         setup_status: RuleMaven.Setup.status(game_id),
         setup_checklist: RuleMaven.Setup.stored_checklist(game_id)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:house_rule_checked, _id}, socket) do
    {:noreply, refresh_house_rules(socket)}
  end

  def handle_info({:house_rule_delta, hr_id, ql_id, status}, socket) do
    cond do
      socket.assigns.active_thread_id != ql_id ->
        {:noreply, socket}

      status == :done ->
        {:noreply, load_hr_overlay(socket)}

      true ->
        {:noreply,
         assign(socket,
           hr_delta_pending: MapSet.delete(socket.assigns.hr_delta_pending, hr_id),
           hr_delta_failed: MapSet.put(socket.assigns.hr_delta_failed, hr_id)
         )}
    end
  end

  def handle_info({:delta_done, _game_id}, socket) do
    {:noreply,
     assign(socket,
       expansion_deltas:
         load_expansion_deltas(socket.assigns.expansions, socket.assigns.included_expansions)
     )}
  end

  # Streamed answer text for a still-pending ask. Only track partials for
  # rows this LiveView is actually showing as pending — every viewer of the
  # game topic receives the broadcast, but only the asker has the pending row.
  # Real pipeline progress from LLM.ask — only track questions this session is
  # actually waiting on (the broadcast goes to every viewer of the game topic).
  def handle_info({:ask_stage, %{question_log_id: ql_id, stage: stage}}, socket) do
    tracked? =
      Enum.any?(
        socket.assigns.conversation,
        &(&1[:id] == ql_id && &1[:role] == :assistant && &1[:pending])
      )

    if tracked? do
      {:noreply,
       assign(socket, ask_stage: Map.put(socket.assigns.ask_stage, ql_id, to_string(stage)))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ask_partial, %{question_log_id: ql_id, text: text} = data}, socket) do
    tracked? =
      Enum.any?(
        socket.assigns.conversation,
        &(&1[:id] == ql_id && &1[:role] == :assistant && &1[:pending])
      )

    if tracked? do
      # `styled_text` streams on the persona-direct path (vetted voice styled
      # in the same ask call); a persona viewer streams that instead of the
      # plain text so the plain answer never flashes. Older payload shape
      # (pre-deploy broadcasts) simply has no :styled_text key.
      partial = %{
        text: text,
        styled: data[:styled_text],
        # Answer/styled_answer string closed on the wire — the visible text
        # is final and the remaining wait is citations + verdict. Older
        # payloads (pre-deploy broadcasts) have no done keys → false.
        text_done: data[:text_done] == true,
        styled_done: data[:styled_done] == true
      }

      {:noreply,
       socket
       |> assign(ask_partial: Map.put(socket.assigns.ask_partial, ql_id, partial))
       |> push_event("scroll_bottom", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:voice_ready, ql_id, voice, content}, socket) do
    cache = Map.put(socket.assigns.voice_cache, {ql_id, voice}, content)
    pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})
    failed = MapSet.delete(socket.assigns.voice_failed, {ql_id, voice})
    {:noreply, assign(socket, voice_cache: cache, voice_pending: pending, voice_failed: failed)}
  end

  def handle_info({:voice_failed, ql_id, voice}, socket) do
    pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})
    failed = MapSet.put(socket.assigns.voice_failed, {ql_id, voice})

    {:noreply,
     socket
     |> assign(voice_pending: pending, voice_failed: failed)
     |> put_flash(:error, "Couldn't apply that persona — showing the plain answer.")}
  end

  def handle_info({:ask_error, data}, socket) do
    question_log_id = data[:question_log_id]
    known_ids = Enum.map(socket.assigns.threads, & &1.id)

    # No-op if question_log_id not in current threads (deleted or from another session)
    if question_log_id && question_log_id not in known_ids do
      {:noreply, socket}
    else
      threads =
        if question_log_id do
          Enum.map(socket.assigns.threads, fn
            %{id: ^question_log_id} = t -> %{t | pending: false}
            t -> t
          end)
        else
          socket.assigns.threads
        end

      conversation =
        if question_log_id && socket.assigns.active_thread_id == question_log_id do
          # Pull the persisted failure classification so the error bubble can
          # offer the right affordance (retry / cooldown / shorten hint)
          # without a page reload.
          err_q = get_question_log_by_id(question_log_id)

          Enum.map(socket.assigns.conversation, fn
            %{id: ^question_log_id, role: :assistant} = msg ->
              msg
              |> Map.delete(:pending)
              |> Map.put(:content, "⚠️ #{data.error}")
              |> Map.put(:error_kind, err_q && err_q.error_kind)
              |> Map.put(:error_retries, (err_q && err_q.error_retries) || 0)

            msg ->
              msg
          end)
        else
          socket.assigns.conversation
        end

      {:noreply,
       socket
       |> assign(
         conversation: conversation,
         threads: threads,
         pending_count: Enum.count(threads, & &1.pending),
         ask_partial: Map.delete(socket.assigns.ask_partial, question_log_id),
         ask_stage: Map.delete(socket.assigns.ask_stage, question_log_id)
       )
       |> push_event("scroll_bottom", %{})}
    end
  end

  def handle_info({:suggestions_ready, qs}, socket) do
    {:noreply, assign(socket, suggestions: qs)}
  end

  # Facts finished generating: swap the raw-chunk fallback for a real fact.
  def handle_info({:did_you_know_ready, facts}, socket) when is_list(facts) and facts != [] do
    {:noreply, assign(socket, dyk_facts: facts, rule_card: fact_card(facts))}
  end

  def handle_info({:did_you_know_ready, _facts}, socket), do: {:noreply, socket}

  # The game's themed persona voices just finished generating — swap the voice
  # list in so the switcher shows them live (already-selected voices unaffected).
  def handle_info({:voices_ready, voices}, socket) when is_list(voices) do
    {:noreply, assign(socket, voices: voices)}
  end

  def handle_info(:check_stale, socket) do
    stale_cutoff = DateTime.utc_now() |> DateTime.add(-120, :second)

    {conversation, stale_count} =
      Enum.reduce(socket.assigns.conversation, {[], 0}, fn msg, {acc, count} ->
        if msg[:pending] && msg.role == :assistant && msg.content == "Thinking..." &&
             not is_nil(msg.timestamp) &&
             DateTime.compare(msg.timestamp, stale_cutoff) != :gt do
          {[Map.delete(msg, :pending) | acc], count + 1}
        else
          {[msg | acc], count}
        end
      end)

    if stale_count > 0 do
      conversation = Enum.reverse(conversation)

      threads =
        Enum.map(socket.assigns.threads, fn t ->
          if t.pending && not is_nil(t.inserted_at) &&
               DateTime.compare(t.inserted_at, stale_cutoff) != :gt do
            %{t | pending: false}
          else
            t
          end
        end)

      pending_count = Enum.count(threads, & &1.pending)

      {:noreply,
       assign(socket,
         conversation: conversation,
         threads: threads,
         pending_count: pending_count,
         refresh: socket.assigns.refresh + 1,
         stale_timer: nil
       )}
    else
      # No stale found — re-arm if questions still pending (they're < 120s old now)
      timer =
        if socket.assigns.pending_count > 0 do
          Process.send_after(self(), :check_stale, 120_000)
        else
          nil
        end

      {:noreply, assign(socket, stale_timer: timer)}
    end
  end

  # One checklist row shared by the base setup checklist (Gather/Steps) and the
  # per-expansion delta sections: a toggle button keyed into @checklist_done.
  # `plain: true` renders a single-line item (Gather / delta components);
  # otherwise renders a bold title with an optional detail line (Steps / delta
  # setup steps) — `detail` is nil for plain items.
  attr :key, :string, required: true
  attr :checked, :boolean, required: true
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :plain, :boolean, default: false

  defp checklist_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_step"
      phx-value-key={@key}
      style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:#{if @plain, do: "0.2rem", else: "0.3rem"} 0;font-size:0.82rem;line-height:1.4;color:#{if @checked, do: "var(--text-muted)", else: "var(--text)"}"}
    >
      <span aria-hidden="true" style="flex-shrink:0">
        {if @checked, do: "☑️", else: "⬜"}
      </span>
      <%= if @plain do %>
        <span style={"flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere;#{if @checked, do: "text-decoration:line-through", else: ""}"}>
          {@title}
        </span>
      <% else %>
        <span style="flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere">
          <span style={"font-weight:600;#{if @checked, do: "text-decoration:line-through", else: ""}"}>
            {@title}
          </span>
          <%= if @detail not in [nil, "", "nil"] do %>
            <span style="display:block;font-size:0.74rem;color:var(--text-muted)">
              {@detail}
            </span>
          <% end %>
        </span>
      <% end %>
    </button>
    """
  end

  attr :rules, :list, required: true
  attr :deltas, :map, required: true
  attr :pending, :any, required: true
  attr :failed, :any, required: true

  # Callout under an answer: each of the user's checked rules that embeds near
  # the question, with its verdict stamp and an on-demand cached delta note.
  defp house_rule_overlay(assigns) do
    ~H"""
    <div style="margin-top:0.75rem;padding:0.6rem 0.75rem;background:var(--bg-subtle);border:1px dashed var(--border);border-radius:0.5rem">
      <div style="display:flex;align-items:center;gap:0.35rem;color:var(--text-muted);font-weight:700;font-size:0.68rem;letter-spacing:0.03em;text-transform:uppercase;margin-bottom:0.4rem">
        <span aria-hidden="true">🏠</span> Your house rule may change this
      </div>

      <div
        :for={hr <- @rules}
        style="padding:0.35rem 0;border-top:1px solid var(--border-subtle);font-size:0.8rem"
      >
        <div style="display:flex;align-items:center;gap:0.4rem;flex-wrap:wrap;margin-bottom:0.2rem">
          <span style="font-weight:600;color:var(--text)">
            {if hr.title not in [nil, ""], do: hr.title, else: String.slice(hr.body, 0, 40)}
          </span>
          <% {emoji, label} = house_rule_stamp(hr.verdict) %>
          <span style="display:inline-flex;align-items:center;gap:0.25rem;padding:0.1rem 0.4rem;border-radius:999px;background:var(--bg-surface);font-weight:700;font-size:0.6rem;letter-spacing:0.02em;text-transform:uppercase;color:var(--text)">
            <span aria-hidden="true">{emoji}</span> {label}
          </span>
        </div>

        <p style="margin:0 0 0.3rem;color:var(--text-secondary);font-size:0.76rem;line-height:1.45">
          {hr.body}
        </p>

        <%= cond do %>
          <% delta = @deltas[hr.id] -> %>
            <p style="margin:0;padding:0.4rem 0.6rem;background:var(--bg-surface);border-left:3px solid var(--accent);border-radius:0.3rem;font-size:0.78rem;line-height:1.5;color:var(--text)">
              {delta}
            </p>
          <% hr.id in @pending -> %>
            <span
              style="font-size:0.72rem;color:var(--text-muted);font-weight:600"
              data-testid="hr-delta-pending"
            >
              ⏳ Working out how this changes the answer…
            </span>
          <% true -> %>
            <button
              type="button"
              phx-click="house_rule_delta"
              phx-value-id={hr.id}
              style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.68rem;cursor:pointer;padding:0.15rem 0.55rem;color:var(--text-muted);font-weight:600"
            >
              {if hr.id in @failed,
                do: "Couldn't explain — retry",
                else: "How does this change the answer?"}
            </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :hr, :map, required: true
  attr :editing, :boolean, required: true
  attr :owner?, :boolean, required: true
  attr :is_admin, :boolean, required: true

  defp house_rule_row(assigns) do
    ~H"""
    <div style="border-top:1px solid var(--border-subtle);padding:0.5rem 0;font-size:0.82rem">
      <%= if @editing do %>
        <form
          phx-submit="edit_house_rule"
          phx-value-id={@hr.id}
          style="display:flex;flex-direction:column;gap:0.35rem"
        >
          <input
            type="text"
            name="house_rule[title]"
            value={@hr.title}
            maxlength="80"
            style="font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text)"
          />
          <textarea
            name="house_rule[body]"
            maxlength="500"
            rows="3"
            style="font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text);resize:vertical"
          >{@hr.body}</textarea>
          <div style="display:flex;gap:0.4rem">
            <button
              type="submit"
              style="background:var(--accent);color:var(--accent-text,#fff);border:none;border-radius:0.3rem;font-size:0.74rem;font-weight:700;padding:0.25rem 0.6rem;cursor:pointer"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel_edit_house_rule"
              style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.74rem;padding:0.25rem 0.6rem;cursor:pointer;color:var(--text-muted)"
            >
              Cancel
            </button>
          </div>
        </form>
      <% else %>
        <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.5rem">
          <div style="flex:1;min-width:0">
            <div style="display:flex;align-items:center;gap:0.4rem;flex-wrap:wrap;margin-bottom:0.2rem">
              <span style="font-weight:600;color:var(--text)">
                {if @hr.title not in [nil, ""], do: @hr.title, else: String.slice(@hr.body, 0, 40)}
              </span>

              <%= cond do %>
                <% @hr.check_status == "pending" -> %>
                  <span
                    style="font-size:0.65rem;color:var(--text-muted);font-weight:600"
                    data-testid="hr-pending"
                  >
                    ⏳ pending
                  </span>
                <% @hr.check_status in ["stale", "failed"] -> %>
                  <button
                    type="button"
                    phx-click="recheck_house_rule"
                    phx-value-id={@hr.id}
                    style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.62rem;cursor:pointer;padding:0.1rem 0.4rem;color:var(--text-muted);font-weight:600"
                  >
                    {if @hr.check_status == "stale",
                      do: "Stale — re-check",
                      else: "Check failed — retry"}
                  </button>
                <% @hr.check_status == "done" -> %>
                  <% {emoji, label} = house_rule_stamp(@hr.verdict) %>
                  <span style="display:inline-flex;align-items:center;gap:0.25rem;padding:0.1rem 0.4rem;border-radius:999px;background:var(--bg-subtle);font-weight:700;font-size:0.62rem;letter-spacing:0.02em;text-transform:uppercase;color:var(--text)">
                    <span aria-hidden="true">{emoji}</span> {label}
                  </span>
                <% true -> %>
              <% end %>
            </div>

            <details>
              <summary style="cursor:pointer;font-size:0.72rem;color:var(--text-muted)">
                {String.slice(@hr.body, 0, 60)}{if String.length(@hr.body) > 60, do: "…"}
              </summary>
              <p style="margin:0.3rem 0 0;color:var(--text)">{@hr.body}</p>
              <%= if @hr.raw_quote not in [nil, ""] do %>
                <blockquote style="margin:0.3rem 0 0;padding:0.3rem 0.6rem;border-left:2px solid var(--border);color:var(--text-muted);font-style:italic;font-size:0.74rem">
                  {@hr.raw_quote}
                </blockquote>
              <% end %>
              <%= if @hr.check_note not in [nil, ""] do %>
                <p style="margin:0.3rem 0 0;font-size:0.74rem;color:var(--text-muted)">
                  {@hr.check_note}
                </p>
              <% end %>
            </details>
          </div>

          <div style="display:flex;align-items:center;gap:0.3rem;flex-shrink:0">
            <%= if @owner? do %>
              <button
                type="button"
                phx-click="toggle_house_rule_visibility"
                phx-value-id={@hr.id}
                title={
                  if @hr.visibility == "community",
                    do: "Community — click to make private",
                    else: "Private — click to share"
                }
                style="background:none;border:none;cursor:pointer;font-size:0.85rem;padding:0.1rem"
              >{if @hr.visibility == "community", do: "🌐", else: "🔒"}</button>
              <button
                type="button"
                phx-click="start_edit_house_rule"
                phx-value-id={@hr.id}
                style="background:none;border:none;cursor:pointer;font-size:0.75rem;padding:0.1rem;color:var(--text-muted)"
              >✏️</button>
              <button
                type="button"
                phx-click="delete_house_rule"
                phx-value-id={@hr.id}
                data-confirm="Delete this house rule?"
                style="background:none;border:none;cursor:pointer;font-size:0.75rem;padding:0.1rem;color:var(--text-muted)"
              >🗑️</button>
            <% end %>
            <%= if @is_admin and not @owner? do %>
              <button
                type="button"
                phx-click="block_house_rule"
                phx-value-id={@hr.id}
                title={
                  if @hr.blocked, do: "Blocked — click to unblock", else: "Block this house rule"
                }
                style="background:none;border:none;cursor:pointer;font-size:0.75rem;padding:0.1rem;color:var(--text-muted)"
              >{if @hr.blocked, do: "🚫", else: "🛑"}</button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  # Players hitting a not-yet-Ready game see only a "not ready" message — none of
  # the Q&A UI. Admins fall through to the full page so they can test it.
  def render(%{game: %{playable: false}, is_admin: false} = assigns) do
    ~H"""
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <div style="max-width:34rem;margin:0 auto;padding:4rem 1.5rem;text-align:center">
      <div style="font-size:2.5rem;margin-bottom:0.75rem">🔒</div>
      <h1 style="font-size:1.4rem;font-weight:700;margin:0 0 0.5rem;color:var(--text-heading,var(--text))">
        {@game.name} isn’t ready yet
      </h1>
      <p style="font-size:0.9rem;color:var(--text-muted);margin:0 0 1.5rem">
        We’re still preparing this game. Check back soon.
      </p>
      <.link navigate={~p"/"} class="back-link">&larr; Back to games</.link>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <%!-- Hosts the spotlight onboarding tour for this page (Hooks.Tour). --%>
    <div
      id="tour-game"
      phx-hook="Tour"
      data-tour-page="game"
      data-tour-also="answer"
      data-tour-autostart={@tour_autostart && "game"}
    >
    </div>
    <div
      :if={@is_admin and RuleMaven.Games.taken_down?(@game)}
      style="position:fixed;top:var(--header-height,3.125rem);left:0;right:0;z-index:20;background:var(--danger,#c0392b);color:#fff;font-size:0.8rem;font-weight:600;padding:0.4rem 0.9rem;text-align:center"
    >
      ⛔ This game is taken down (DMCA) — hidden from users, asks blocked.
      <.link navigate={~p"/admin/takedowns"} style="color:#fff;text-decoration:underline">Manage</.link>
    </div>
    <div
      class="chat-layout"
      data-refresh={@refresh}
      style="display:flex;flex-direction:column;height:calc(100dvh - var(--header-height, 3.125rem) - var(--jobpanel-h, 0px));position:fixed;top:var(--header-height, 3.125rem);left:0;right:0;bottom:var(--jobpanel-h, 0px);z-index:10;background:var(--bg)"
    >
      <%!-- Faint blurred cover art behind the Q&A. The message column is opaque
            and centered, so this only shows in the side gutters — keeping the
            scroll on the fast opaque path (a transparent scroller forces a full
            repaint every frame). Blur a quarter-size surface scaled 4x so the
            filter runs over ~1/16 the pixels, painted once. --%>
      <div
        :if={@game.image_url}
        aria-hidden="true"
        style={"position:absolute;top:0;left:0;width:25%;height:25%;z-index:0;transform-origin:top left;transform:scale(4);background-image:url('#{@game.image_url}');background-size:cover;background-position:center;filter:blur(5px) saturate(1.15);opacity:0.22;pointer-events:none"}
      >
      </div>
      <!-- Header -->
      <div
        class="chat-header"
        style="flex-shrink:0;padding:0.25rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface);position:relative;z-index:20"
      >
        <div class="flex items-center justify-between" style="flex-wrap:wrap;gap:0.35rem">
          <div class="flex items-center gap-1" style="min-width:0;flex-wrap:wrap">
            <.link navigate={~p"/"} class="action-link" style="flex-shrink:0">
              &larr;
            </.link>
            <.link
              patch={~p"/games/#{@game}?start=1"}
              title="Game overview"
              style="display:inline-flex;align-items:center;gap:0.25rem;min-width:0;text-decoration:none;color:inherit"
            >
              <h1 class="text-sm font-bold truncate" style="max-width:300px">{@game.name}</h1>
              <.difficulty_badge weight={
                difficulty_weight(@game, {@expansions, @included_expansions})
              } />
            </.link>
            <.link patch={~p"/games/#{@game}?start=1"} class="pill-link pill-link-accent">
              Overview
            </.link>
            <%= if @game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(@game.category) do %>
              <.link
                href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
                target="_blank"
                rel="noopener"
                class="pill-link"
              >View on BGG</.link>
            <% end %>
          </div>
          <div class="flex items-center gap-1" style="flex-wrap:wrap">
            <%!-- Sidebar toggle: kept first so it is the leftmost control on
                  whichever row this group wraps onto on narrow screens. --%>
            <button
              type="button"
              phx-click="toggle_sidebar"
              class="sidebar-toggle"
              style="background:none;border:1px solid var(--border);border-radius:0.3rem;padding:0.15rem 0.4rem;font-size:0.8rem;cursor:pointer;color:var(--text)"
            >☰</button>
            <%!-- Rulebook sources dropdown --%>
            <details
              :if={@sources != []}
              class="sources-dropdown"
              style="flex-shrink:0;position:relative;display:inline-flex;align-items:center"
            >
              <summary
                class="pill-link"
                style="cursor:pointer;list-style:none;gap:0.2rem;user-select:none"
              >
                <span>📖</span>
                <span>Rulebooks</span>
                <span style="font-size:0.6rem;opacity:0.6">▾</span>
              </summary>
              <div style="position:absolute;right:0;top:calc(100% + 0.35rem);z-index:200;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;box-shadow:0 6px 20px rgba(0,0,0,0.18);min-width:200px;max-width:min(320px,calc(100vw - 2rem));overflow:hidden">
                <%= for {src, i} <- Enum.with_index(@sources) do %>
                  <div style={"padding:0.5rem 0.75rem;#{if i > 0, do: "border-top:1px solid var(--border-subtle)"}"}>
                    <div style="font-size:0.78rem;font-weight:600;color:var(--text);margin-bottom:0.25rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
                      {src.label}
                    </div>
                    <%!-- Rulebooks may be copyrighted, so regular users see
                            only the source name — no PDF, no full text. Admins
                            get the extracted-text HTML view. --%>
                    <div :if={@is_admin and src.html_path} style="display:flex;gap:0.5rem">
                      <.link
                        href={~p"/rulebooks/#{src}/html"}
                        target="_blank"
                        style="display:inline-flex;align-items:center;gap:0.2rem;color:var(--blue);font-size:0.7rem;font-weight:600;text-decoration:none;padding:0.15rem 0.4rem;border:1px solid var(--blue);border-radius:0.25rem;opacity:0.85"
                      >🔗 HTML</.link>
                      <button
                        type="button"
                        phx-click="regenerate_html"
                        phx-value-id={src.id}
                        title="Re-render the HTML view from the current text"
                        style="display:inline-flex;align-items:center;gap:0.2rem;color:var(--text-secondary);font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border:1px solid var(--border);border-radius:0.25rem;background:none;cursor:pointer"
                      >↻ Regen</button>
                    </div>
                  </div>
                <% end %>
              </div>
            </details>
            <%!-- Community --%>
            <%= if @community_count > 0 do %>
              <.link
                navigate={~p"/games/#{@game}/community"}
                style="display:inline-flex;align-items:center;gap:0.25rem;background:var(--accent);color:var(--accent-text,#fff);border:1px solid var(--accent);text-decoration:none;font-size:0.72rem;font-weight:700;padding:0.25rem 0.6rem;border-radius:0.35rem;flex-shrink:0;box-shadow:0 1px 4px color-mix(in srgb,var(--accent) 40%,transparent)"
              >
                <span aria-hidden="true">💬</span> Community Q&amp;A ({@community_count})
              </.link>
            <% end %>
            <%!-- Cheat Sheet --%>
            <%= if Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil)) do %>
              <.link
                href={~p"/games/#{@game}/cheatsheet"}
                target="_blank"
                style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
              >
                Cheat Sheet
              </.link>
            <% end %>
            <details
              :if={RuleMaven.Users.can?(@current_user, :admin)}
              class="card-menu"
              style="flex-shrink:0"
            >
              <summary
                class="action-link"
                style="display:inline-flex;align-items:center;gap:0.2rem"
                title="Admin actions"
              >
                Admin <span style="font-size:0.6rem;opacity:0.6">▾</span>
              </summary>
              <div class="card-menu__pop card-menu__pop--right">
                <.link navigate={~p"/games/#{@game}/edit"} class="card-menu__item">
                  ✏️ Edit
                </.link>
                <.link navigate={~p"/games/#{@game}/review"} class="card-menu__item">
                  🔍 Review
                </.link>
                <.link
                  :if={RuleMaven.Games.bgg_synced?(@game)}
                  href={~p"/games/#{@game}/prepare"}
                  class="card-menu__item"
                >
                  🚀 Prepare
                </.link>
              </div>
            </details>
          </div>
        </div>
      </div>

      <div style="display:flex;flex:1;min-height:0">
        <!-- Sidebar backdrop (mobile only). Always rendered (not :if) so toggling
             the sidebar doesn't insert/remove a sibling — that sibling shift made
             LiveView rebuild the adjacent .chat-messages node, replaying its
             entrance animation every time the menu opened. -->
        <div
          class={"sidebar-backdrop #{if @sidebar_open, do: "open"}"}
          phx-click="toggle_sidebar"
          style="position:fixed;top:0;left:0;right:0;bottom:0;z-index:49;background:rgba(0,0,0,0.3)"
        >
        </div>

        <!-- Question sidebar: shows all threads -->
        <div
          id="question-sidebar"
          class={"question-sidebar #{if @sidebar_open, do: "", else: "sidebar-closed"}"}
          style="flex-shrink:0;width:16rem;overflow-y:auto;border-right:1px solid var(--border);background:color-mix(in srgb,var(--bg-surface) 50%,transparent);backdrop-filter:blur(7px);-webkit-backdrop-filter:blur(7px);padding:0.5rem 0;font-size:0.9rem;display:flex;flex-direction:column;position:relative;z-index:1"
        >
          <div style="padding:0.35rem 0.75rem;font-size:0.78rem;font-weight:600;color:var(--text);text-transform:uppercase;display:flex;justify-content:space-between;align-items:center">
            <span>
              Questions
              <%= if @pending_count > 0 do %>
                <span style="display:inline-flex;align-items:center;justify-content:center;background:var(--accent);color:var(--accent-text,#fff);border-radius:9999px;font-size:0.55rem;font-weight:700;padding:0 0.3rem;min-width:1.1em;height:1.1em;vertical-align:middle;margin-left:0.25rem">{@pending_count}</span>
              <% end %>
            </span>
            <button
              type="button"
              phx-click="toggle_sidebar"
              class="sidebar-close-btn"
              style="background:none;border:none;font-size:1rem;cursor:pointer;color:var(--text);padding:0;line-height:1"
            >✕</button>
          </div>

          <!-- Search -->
          <div style="padding:0.25rem 0.75rem 0.5rem">
            <form
              phx-change="search"
              phx-submit="search"
              style="position:relative;display:flex;align-items:center"
            >
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search questions..."
                phx-debounce="200"
                style="width:100%;border:1px solid var(--border);border-radius:0.4rem;padding:0.3rem 1.6rem 0.3rem 0.5rem;font-size:0.72rem;background:var(--bg);color:var(--text)"
                autocomplete="off"
              />
              <%= if @search_query != "" do %>
                <button
                  type="button"
                  phx-click="clear_search"
                  style="position:absolute;right:0.3rem;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--text-muted);cursor:pointer;padding:0;font-size:0.75rem;line-height:1"
                  title="Clear"
                >✕</button>
              <% end %>
            </form>
          </div>

          <!-- Community questions -->
          <%= if @community_questions != [] do %>
            <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
              Community
            </div>
            <%= for q <- @community_questions do %>
              <%= if @search_query == "" || String.contains?(String.downcase(q.question), String.downcase(@search_query)) do %>
                <button
                  id={"community-#{q.id}"}
                  type="button"
                  class="sidebar-item"
                  phx-click="switch_thread"
                  phx-value-id={q.id}
                  style={"display:block;text-align:left;border:none;cursor:pointer;padding:0.25rem 0.75rem;color:var(--text-secondary);font-size:0.72rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == q.id, do: "var(--accent)", else: "var(--border-subtle)"};width:100%"}
                >
                  <span style="word-break:break-word;white-space:normal;display:block;line-height:1.3">
                    <%= if MapSet.member?(@favorited_answer_ids, q.id) do %>
                      <span style="color:#e05c2a;font-size:0.55rem">♥</span>
                    <% end %>
                    {QuestionLog.display_question(q)}
                  </span>
                </button>
              <% end %>
            <% end %>
            <div style="border-bottom:1px solid var(--border-subtle);margin:0.25rem 0.75rem 0.25rem">
            </div>
          <% end %>

          <!-- Thread list grouped by time -->
          <% community_ids = MapSet.new(@community_questions, & &1.id) %>
          <% answered =
            if @is_admin do
              Enum.reject(@threads, fn t -> MapSet.member?(community_ids, t.id) end)
            else
              Enum.reject(@threads, fn t ->
                t.refused || MapSet.member?(community_ids, t.id)
              end)
            end %>
          <% refused = if @is_admin, do: [], else: Enum.filter(@threads, & &1.refused) %>
          <% refused_count = length(refused) %>
          <%!-- Favorites get their own section above the time groups (not just
                floated within Today), so an old favorited question stays
                pinned even once it's aged out of "Today". --%>
          <% {favorited_threads, unfavorited} = Enum.split_with(answered, & &1.favorited) %>
          <% favorited_threads = Enum.filter(favorited_threads, &matches_search?(&1, @search_query)) %>
          <% groups = group_threads_by_time(unfavorited) %>
          <% refused_groups = group_threads_by_time(refused) %>

          <%= if favorited_threads != [] do %>
            <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
              Favorites
            </div>
            <.thread_sidebar_item
              :for={t <- favorited_threads}
              t={t}
              active_thread_id={@active_thread_id}
              show_asker={@is_admin}
              voice_pending={@voice_pending}
            />
          <% end %>

          <%= for {label, key} <- [{"Today", :today}, {"Last 7 Days", :week}, {"Older", :older}] do %>
            <% items = Map.get(groups, key, []) |> Enum.filter(&matches_search?(&1, @search_query)) %>
            <%= if items != [] do %>
              <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
                {label}
              </div>
              <.thread_sidebar_item
                :for={t <- items}
                t={t}
                active_thread_id={@active_thread_id}
                show_asker={@is_admin}
                voice_pending={@voice_pending}
              />
            <% end %>
          <% end %>

          <!-- Refused toggle -->
          <%= if refused_count > 0 do %>
            <div style="padding:0.4rem 0.75rem 0.2rem">
              <button
                type="button"
                phx-click="toggle_refused"
                style="background:none;border:none;padding:0;cursor:pointer;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;display:flex;align-items:center;gap:0.25rem"
              >
                <span>{if @show_refused, do: "▾", else: "▸"}</span> Not Covered ({refused_count})
              </button>
            </div>
            <%= if @show_refused do %>
              <%= for {label, key} <- [{"Today", :today}, {"Last 7 Days", :week}, {"Older", :older}] do %>
                <% ritems =
                  Map.get(refused_groups, key, [])
                  |> Enum.filter(fn t ->
                    @search_query == "" ||
                      String.contains?(String.downcase(t.question), String.downcase(@search_query))
                  end) %>
                <%= if ritems != [] do %>
                  <div style="padding:0.2rem 0.75rem 0.05rem 1.1rem;font-size:0.58rem;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.04em;opacity:0.7">
                    {label}
                  </div>
                  <%= for t <- ritems do %>
                    <button
                      id={"thread-#{t.id}"}
                      type="button"
                      class="sidebar-item-muted"
                      phx-click="switch_thread"
                      phx-value-id={t.id}
                      style={"display:block;text-align:left;background:none;border:none;cursor:pointer;padding:0.22rem 0.75rem 0.22rem 1.1rem;font-size:0.73rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == t.id, do: "var(--accent)", else: "transparent"};width:100%;color:var(--text-muted)"}
                    >
                      <span style="word-break:break-word;white-space:normal">{t.question}</span>
                    </button>
                  <% end %>
                <% end %>
              <% end %>
            <% end %>
          <% end %>

          <%= if @search_query != "" &&
               Enum.all?(@threads, fn t -> not matches_search?(t, @search_query) end) &&
               Enum.all?(@community_questions, fn q -> @search_query == "" || not String.contains?(String.downcase(q.question), String.downcase(@search_query)) end) do %>
            <div style="padding:0.5rem 0.75rem;color:var(--text-muted);font-size:0.72rem;font-style:italic">
              No matching questions
            </div>
          <% end %>
          <div
            :if={@threads == [] && @community_questions == []}
            style="padding:0.5rem 0.75rem;color:var(--text);font-size:0.8rem"
          >
            No questions yet
          </div>
        </div>

        <!-- Restores the saved default voice from localStorage on connect. -->
        <div id="voice-default-store" phx-hook="VoiceDefault" style="display:none"></div>

        <!-- Messages -->
        <div
          id="chat-messages"
          class="chat-messages"
          style="flex:1;overflow-y:auto;overflow-x:hidden;padding:1rem;display:flex;flex-direction:column;gap:1rem;background:var(--bg);max-width:48rem;margin:0 auto;width:100%;min-width:0;position:relative;z-index:1"
          phx-hook="ChatScroll"
        >
          <%= if @source_count == 0 do %>
            <div class="text-center text-gray-400 py-8">
              <p class="text-sm">No rulebook sources yet.</p>
              <.link
                :if={RuleMaven.Users.can?(@current_user, :admin)}
                navigate={~p"/games/#{@game}/edit"}
                style="background:var(--accent);color:var(--accent-text,#fff);text-decoration:none;font-size:0.8rem;font-weight:600;padding:0.3rem 0.75rem;border-radius:0.3rem"
              >
                Add rulebook text or PDF
              </.link>
            </div>
          <% end %>

          <!-- Persistent Did-you-know: once a conversation starts the full
               empty-state card is gone, so keep a slim sticky version pinned
               above the answers (a fast reply otherwise steals the fact). -->
          <%= if @rule_card && @conversation != [] do %>
            <div style="position:sticky;top:-1rem;z-index:5;margin:-1rem -1rem 1rem;padding:0.4rem 2rem 0.4rem 0.75rem;background:var(--bg-surface);border-bottom:1px solid var(--border);box-shadow:0 3px 8px rgba(0,0,0,0.07);font-size:0.72rem;line-height:1.35;color:var(--text)">
              <button
                type="button"
                phx-click="shuffle_rule"
                title="Another rule"
                style="position:absolute;top:0.4rem;right:0.5rem;background:none;border:1px solid var(--border);border-radius:999px;font-size:0.65rem;cursor:pointer;padding:0.12rem 0.45rem;color:var(--text-muted);font-weight:600"
              >🔀</button>
              <span style="font-weight:800;letter-spacing:0.03em;text-transform:uppercase;color:var(--accent-ink,var(--accent))">💡 Did you know?</span>
              {clean_rule_text(@rule_card.content)}
              <span :if={@rule_card.page_number} style="color:var(--text-muted);white-space:nowrap">· p.{@rule_card.page_number}</span>
            </div>
          <% end %>

          <%= if @conversation == [] && @source_count > 0 do %>
            <!-- Empty state: lead with the primary action, suggestions visible immediately -->
            <div
              class="answer-in"
              style="text-align:center;padding:2rem 1rem;color:var(--text-secondary);font-size:0.85rem;line-height:1.6;position:relative;z-index:1"
            >
              <%= if @game.image_url do %>
                <img
                  src={@game.image_url}
                  alt={@game.name}
                  style="width:120px;height:120px;object-fit:cover;border-radius:0.75rem;margin:0 auto 0.75rem;box-shadow:0 4px 16px rgba(0,0,0,0.18)"
                />
              <% else %>
                <div style="font-size:1.5rem;margin-bottom:0.4rem">🎲</div>
              <% end %>
              <p style="font-size:1.15rem;font-weight:700;color:var(--text);margin-bottom:0.4rem">
                {@game.name} Rules
              </p>
              <% stats = bgg_stats(@game) %>
              <%= if stats != [] || @game.weight do %>
                <div style="display:flex;flex-wrap:wrap;justify-content:center;align-items:center;gap:0.4rem;margin:0 auto 0.75rem;max-width:30rem">
                  <.difficulty_badge weight={
                    difficulty_weight(@game, {@expansions, @included_expansions})
                  } />
                  <span
                    :for={{icon, label} <- stats}
                    style="display:inline-flex;align-items:center;gap:0.25rem;background:var(--bg-surface);border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.55rem;font-size:0.7rem;font-weight:600;color:var(--text-secondary)"
                  >
                    <span aria-hidden="true">{icon}</span> {label}
                  </span>
                  <.link
                    :if={@game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(@game.category)}
                    href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
                    target="_blank"
                    rel="noopener"
                    style="display:inline-flex;align-items:center;gap:0.25rem;border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.55rem;font-size:0.7rem;font-weight:600;color:var(--blue);text-decoration:none"
                  >
                    View on BGG ↗
                  </.link>
                </div>
              <% end %>
              <p style="max-width:30rem;margin:0 auto">
                Ask any rules question in plain English — answers cite the exact rulebook passage.
                <%= if @community_count > 0 do %>
                  <.link
                    navigate={~p"/games/#{@game}/community"}
                    style="color:var(--accent-ink,var(--accent));font-weight:600;white-space:nowrap"
                  >Or browse {@community_count} community answers →</.link>
                <% end %>
              </p>

              <%= if @rule_card do %>
                <div
                  data-tour="dyk"
                  style="margin:1.5rem auto 0;max-width:30rem;text-align:left;background:linear-gradient(135deg,var(--bg-subtle),var(--bg-surface));border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.1rem;box-shadow:0 1px 3px rgba(0,0,0,0.06)"
                >
                  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:0.5rem">
                    <span style="font-size:0.7rem;font-weight:800;letter-spacing:0.05em;text-transform:uppercase;color:var(--accent-ink,var(--accent))">
                      💡 Did you know?
                    </span>
                    <button
                      type="button"
                      phx-click="shuffle_rule"
                      title="Another rule"
                      style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.65rem;cursor:pointer;padding:0.12rem 0.5rem;color:var(--text-muted);font-weight:600"
                    >🔀 Shuffle</button>
                  </div>
                  <p style="font-size:0.85rem;line-height:1.55;color:var(--text);margin:0">
                    {clean_rule_text(@rule_card.content)}
                  </p>
                  <%= if @rule_card.page_number do %>
                    <div style="margin-top:0.5rem;font-size:0.65rem;font-weight:600;text-transform:uppercase;letter-spacing:0.02em;color:var(--text-muted)">
                      📎 Rulebook · p.{@rule_card.page_number}
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%= if @setup_checklist && (@setup_checklist["components"] != [] || @setup_checklist["setup"] != []) do %>
                <div style="margin:1.25rem auto 0;max-width:30rem;text-align:left">
                  <% delta_total =
                    Enum.reduce(@expansion_deltas, 0, fn {_e, d}, acc ->
                      acc + length(d["components"]) + length(d["setup"])
                    end) %>
                  <% total =
                    length(@setup_checklist["components"]) + length(@setup_checklist["setup"]) +
                      delta_total %>
                  <% done = MapSet.size(@checklist_done) %>
                  <div
                    id="setup-checklist"
                    phx-hook="ChecklistStore"
                    data-game-id={@game.id}
                    style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.1rem"
                  >
                    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:0.6rem">
                      <span style="font-size:0.78rem;font-weight:800;letter-spacing:0.03em;text-transform:uppercase;color:var(--text)">
                        🧩 Setup checklist
                      </span>
                      <div style="display:flex;align-items:center;gap:0.5rem">
                        <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">
                          {done}/{total} done
                        </span>
                        <button
                          type="button"
                          phx-click="reset_checklist"
                          style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted);font-weight:600"
                        >🗑️ Clear</button>
                      </div>
                    </div>

                    <%= if @setup_checklist["components"] != [] do %>
                      <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.3rem 0 0.3rem">
                        Gather
                      </div>
                      <%= for {item, i} <- Enum.with_index(@setup_checklist["components"]) do %>
                        <% key = "c-#{i}" %>
                        <.checklist_item
                          key={key}
                          checked={MapSet.member?(@checklist_done, key)}
                          title={item}
                          plain={true}
                        />
                      <% end %>
                    <% end %>

                    <%= if @setup_checklist["setup"] != [] do %>
                      <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.6rem 0 0.3rem">
                        Steps
                      </div>
                      <%= for {step, i} <- Enum.with_index(@setup_checklist["setup"]) do %>
                        <% key = "s-#{i}" %>
                        <.checklist_item
                          key={key}
                          checked={MapSet.member?(@checklist_done, key)}
                          title={step["title"]}
                          detail={step["detail"]}
                        />
                      <% end %>
                    <% end %>

                    <%= for {exp, delta} <- @expansion_deltas do %>
                      <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--accent);margin:0.8rem 0 0.3rem">
                        ➕ {exp.name}
                      </div>
                      <%= for {item, i} <- Enum.with_index(delta["components"]) do %>
                        <% key = "xc-#{exp.id}-#{i}" %>
                        <.checklist_item
                          key={key}
                          checked={MapSet.member?(@checklist_done, key)}
                          title={item}
                          plain={true}
                        />
                      <% end %>
                      <%= for {step, i} <- Enum.with_index(delta["setup"]) do %>
                        <% key = "xs-#{exp.id}-#{i}" %>
                        <.checklist_item
                          key={key}
                          checked={MapSet.member?(@checklist_done, key)}
                          title={step["title"]}
                          detail={step["detail"]}
                        />
                      <% end %>
                    <% end %>

                    <button
                      type="button"
                      phx-click="reset_checklist"
                      style="margin-top:0.6rem;background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted);font-weight:600"
                    >🗑️ Clear</button>
                  </div>
                </div>
              <% end %>

              <div
                data-tour="house-rules"
                style="margin:1.25rem auto 0;max-width:30rem;text-align:left"
              >
                <% own_count = length(@house_rules) %>
                <% community_count_hr = length(@community_house_rules) %>
                <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.1rem">
                  <button
                    type="button"
                    phx-click="toggle_house_rules_card"
                    style="display:flex;align-items:center;justify-content:space-between;width:100%;background:none;border:none;cursor:pointer;padding:0;margin-bottom:0.6rem"
                  >
                    <span style="font-size:0.78rem;font-weight:800;letter-spacing:0.03em;text-transform:uppercase;color:var(--text)">
                      🏠 House rules
                    </span>
                    <div style="display:flex;align-items:center;gap:0.5rem">
                      <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">
                        {own_count + community_count_hr}
                      </span>
                      <span style="font-size:0.7rem;color:var(--text-muted)">
                        {if @hr_card_open, do: "▾", else: "▸"}
                      </span>
                    </div>
                  </button>

                  <%= if @hr_card_open do %>
                    <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.3rem 0 0.3rem">
                      Your house rules
                    </div>

                    <%= for hr <- @house_rules do %>
                      <.house_rule_row
                        hr={hr}
                        editing={@hr_editing_id == hr.id}
                        owner?={true}
                        is_admin={@is_admin}
                      />
                    <% end %>

                    <%= if @house_rules == [] do %>
                      <p style="font-size:0.76rem;color:var(--text-muted);margin:0 0 0.4rem">
                        No house rules yet — add one below.
                      </p>
                    <% end %>

                    <%= if @hr_form_open do %>
                      <form
                        id="house-rule-form"
                        phx-submit="add_house_rule"
                        style="margin-top:0.5rem;display:flex;flex-direction:column;gap:0.4rem"
                      >
                        <input
                          type="text"
                          name="house_rule[title]"
                          placeholder="Title (optional)"
                          maxlength="80"
                          style="font-size:0.8rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text)"
                        />
                        <textarea
                          name="house_rule[body]"
                          placeholder="Describe the house rule…"
                          maxlength="500"
                          rows="3"
                          style="font-size:0.8rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text);resize:vertical"
                        ></textarea>
                        <div style="display:flex;gap:0.4rem">
                          <button
                            type="submit"
                            style="background:var(--accent);color:var(--accent-text,#fff);border:none;border-radius:0.3rem;font-size:0.76rem;font-weight:700;padding:0.35rem 0.75rem;cursor:pointer"
                          >
                            Add house rule
                          </button>
                          <button
                            type="button"
                            phx-click="toggle_house_rule_form"
                            style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.76rem;padding:0.35rem 0.75rem;cursor:pointer;color:var(--text-muted)"
                          >
                            Cancel
                          </button>
                        </div>
                      </form>
                    <% else %>
                      <button
                        type="button"
                        phx-click="toggle_house_rule_form"
                        style="margin-top:0.3rem;background:none;border:1px dashed var(--border);border-radius:0.3rem;font-size:0.76rem;padding:0.3rem 0.6rem;cursor:pointer;color:var(--text-muted);font-weight:600"
                      >
                        + Add a house rule
                      </button>
                    <% end %>

                    <%= if @community_house_rules != [] do %>
                      <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.8rem 0 0.3rem">
                        Community house rules
                      </div>

                      <%= for hr <- @community_house_rules do %>
                        <.house_rule_row hr={hr} editing={false} owner?={false} is_admin={@is_admin} />
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
              </div>

              <%= if @suggestions != [] && !Enum.any?(@conversation, & &1[:refused]) do %>
                <div style="margin-top:1.5rem;text-align:left;max-width:28rem;margin-left:auto;margin-right:auto">
                  <div style="font-size:0.8rem;font-weight:600;color:var(--text);margin-bottom:0.75rem">
                    Suggested questions
                  </div>
                  <%= for cat <- @suggestions do %>
                    <div style="margin-bottom:1rem">
                      <div style="font-size:0.75rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;margin-bottom:0.3rem">
                        {cat.category}
                      </div>
                      <%= for q <- cat.questions do %>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q={q}
                          disabled={@pending_count >= @max_concurrent}
                          style="display:block;width:100%;text-align:left;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.3rem;padding:0.3rem 0.6rem;margin-bottom:0.2rem;font-size:0.82rem;color:var(--text);cursor:pointer;white-space:normal;word-break:break-word;line-height:1.45"
                        >{q}</button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= for {msg, idx} <- @conversation |> Enum.with_index() do %>
            <%= if msg[:history] do %>
              <details style="width:100%;margin-bottom:0.1rem">
                <summary style="font-size:0.72rem;color:var(--text-muted);cursor:pointer;list-style:none;padding:0.15rem 0.5rem;border-radius:0.25rem;background:var(--bg-subtle);display:inline-block">
                  <span>▸ Previous attempt</span>
                </summary>
                <div style="margin-top:0.25rem;padding:0.5rem;border-left:2px solid var(--border-subtle);opacity:0.8">
                  <div style="font-size:0.82rem;color:var(--text)">
                    {render_markdown(msg.content)}
                  </div>
                </div>
              </details>
            <% else %>
              <div
                id={"chat-msg-#{@active_thread_id}-#{idx}"}
                class={[
                  "chat-msg",
                  msg.role == :user && "chat-msg-user"
                ]}
                style={"display:flex;flex-direction:column;align-items:#{if msg.role == :user, do: "flex-end", else: "flex-start"}"}
              >
                <div style={"max-width:85%;padding:0.75rem 1rem;border-radius:0.85rem;font-size:0.95rem;line-height:1.4;box-shadow:0 1px 3px rgba(0,0,0,0.08);#{if msg.role == :user, do: "background:var(--accent);color:var(--accent-text,#fff);border-bottom-right-radius:0.25rem;margin-left:auto", else: "background:var(--bg-surface);color:var(--text);border-bottom-left-radius:0.25rem"}#{if msg[:refused], do: ";opacity:0.72", else: ""}"}>
                  <% stamp =
                    msg.role == :assistant && msg.content != "Thinking..." &&
                      verdict_stamp(msg[:verdict]) %>
                  <% show_voice =
                    msg.role == :assistant && !msg[:refused] &&
                      msg.content != "Thinking..." && !msg[:pending] &&
                      not String.starts_with?(to_string(msg.content), "⚠️") %>
                  <%!-- While the answer is still pending, reserve the top row with a
                        skeleton stamp and a disabled persona selector so the real
                        ones don't pop in later and push the answer down. --%>
                  <% row_placeholder? = msg.role == :assistant && msg[:pending] %>
                  <%!-- Top row: verdict stamp + voice switcher (which persona is
                        speaking) + default-voice star, visible before reading. --%>
                  <%= if stamp || show_voice || row_placeholder? do %>
                    <div style="display:flex;align-items:center;gap:0.45rem;flex-wrap:wrap;margin-bottom:0.5rem">
                      <%= if stamp do %>
                        <% {emoji, label, color, bg} = stamp %>
                        <div
                          class="verdict-stamp"
                          style={"display:inline-flex;align-items:center;gap:0.3rem;padding:0.2rem 0.55rem;border-radius:999px;background:#{bg};color:#{color};font-weight:800;font-size:0.7rem;letter-spacing:0.04em;text-transform:uppercase"}
                        >
                          <span aria-hidden="true">{emoji}</span> {label}
                        </div>
                      <% end %>
                      <%= if !stamp && row_placeholder? do %>
                        <div
                          class="verdict-stamp verdict-stamp--pending"
                          style="display:inline-flex;align-items:center;gap:0.3rem;padding:0.2rem 0.55rem;border-radius:999px;background:var(--bg-subtle);color:var(--text-muted);font-weight:800;font-size:0.7rem;letter-spacing:0.04em;text-transform:uppercase;animation:pulse 1.6s ease-in-out infinite"
                        >
                          <span aria-hidden="true">⏳</span> Checking rules
                        </div>
                      <% end %>
                      <%= if show_voice do %>
                        <% {conf_label, conf_level, conf_color, conf_help, conf_next} =
                          answer_confidence(msg) %>
                        <div
                          class="conf-pill"
                          aria-label={"Confidence: #{conf_word(conf_level)} (#{conf_level} of #{conf_max()})"}
                        >
                          <span class="conf-pill__dots" aria-hidden="true">
                            <span
                              :for={seg <- 1..conf_max()}
                              class="conf-pill__dot"
                              style={if seg <= conf_level, do: "background:#{conf_color}"}
                            />
                          </span>
                          <span style={"color:#{conf_color};font-weight:700"}>{conf_word(conf_level)}</span>
                          <span style="opacity:0.75">· {conf_label}</span>
                          <span class="conf-help">
                            <button
                              type="button"
                              class="conf-help__btn"
                              aria-label={"What \"#{conf_label}\" means"}
                            >?</button>
                            <span class="conf-help__pop" role="tooltip">
                              {conf_help}
                              <span
                                :if={conf_next}
                                style="display:block;margin-top:0.4rem;padding-top:0.4rem;border-top:1px solid rgba(255,255,255,0.2)"
                              >
                                <span style="font-weight:700">Next level:</span> {conf_next}
                              </span>
                            </span>
                          </span>
                        </div>
                      <% end %>
                      <%= if show_voice || row_placeholder? do %>
                        <% cur_voice = Map.get(@voice_sel, msg[:id], @default_voice) %>
                        <% cur = Enum.find(@voices, &(&1.id == cur_voice)) || hd(@voices) %>
                        <% speaking = cur_voice != "neutral" %>
                        <details
                          class="card-menu"
                          style={if !show_voice, do: "opacity:0.55;pointer-events:none", else: nil}
                          aria-disabled={!show_voice}
                        >
                          <summary
                            style={"font-size:0.65rem;font-weight:600;border-radius:999px;padding:0.12rem 0.5rem;#{if speaking, do: "border:1px solid color-mix(in srgb,var(--accent) 55%,transparent);background:color-mix(in srgb,var(--accent) 12%,transparent);color:var(--text)", else: "border:1px solid var(--border);background:var(--bg-surface);color:var(--text-muted)"}"}
                            title="Answer persona — your pick applies to every answer and is remembered"
                          >
                            <span
                              :if={String.starts_with?(cur_voice, "g:")}
                              aria-hidden="true"
                              style="color:var(--accent)"
                              title={"#{@game.name} persona"}
                            >✦</span>
                            <span aria-hidden="true">{cur.emoji}</span>
                            <span>{if speaking,
                              do: "#{cur.label} speaking",
                              else: "#{cur.label} persona"}</span>
                            <span style="opacity:0.6">▾</span>
                          </summary>
                          <.voice_menu
                            :if={show_voice}
                            voices={@voices}
                            game_name={@game.name}
                            current={cur_voice}
                            event="set_voice"
                            msg_id={msg[:id]}
                          />
                        </details>
                      <% end %>
                    </div>
                  <% end %>
                  <%= if msg.role == :assistant && msg[:refused] && is_nil(msg[:verdict]) do %>
                    <div style="font-size:0.6rem;opacity:0.55;margin-bottom:0.15rem;color:var(--text-muted)">
                      ⚐ not covered
                    </div>
                  <% end %>
                  <div>
                    <%!-- A refused answer is never restylable (VoiceWorker skips
                          it), so force neutral — otherwise the waiting? branch
                          below would show a loader that never resolves. --%>
                    <% v_sel =
                      (msg.role == :assistant && !msg[:refused] &&
                         Map.get(@voice_sel, msg[:id], @default_voice)) ||
                        "neutral" %>
                    <% v_content =
                      if v_sel == "neutral" or msg.content == "Thinking...",
                        do: nil,
                        else: Map.get(@voice_cache, {msg[:id], v_sel}) %>
                    <% v_failed = MapSet.member?(@voice_failed, {msg[:id], v_sel}) %>
                    <% partial =
                      msg.role == :assistant && msg[:pending] &&
                        Map.get(@ask_partial, msg[:id]) %>
                    <%!-- A persona viewer only ever sees persona text: stream the
                          styled_answer partial when the single-call path emits one,
                          and show the voice loader through every other wait (plain
                          text streaming underneath, pool-hit restyle in flight) —
                          the plain answer must never flash first. Neutral viewers
                          stream the plain partial as before. A failed restyle
                          falls through to the plain answer. --%>
                    <% stream_text =
                      case partial do
                        %{styled: styled, text: text} ->
                          if v_sel == "neutral", do: text, else: styled

                        _ ->
                          nil
                      end %>
                    <% stream_done =
                      case partial do
                        %{} = p ->
                          (v_sel == "neutral" && p[:text_done] == true) ||
                            (v_sel != "neutral" && p[:styled_done] == true)

                        _ ->
                          false
                      end %>
                    <% thinking? = msg.content == "Thinking..." && msg[:pending] %>
                    <% voicing? =
                      msg.content != "Thinking..." && v_sel != "neutral" && is_nil(v_content) &&
                        not v_failed %>
                    <%= cond do %>
                      <% thinking? && stream_text -> %>
                        <div class="answer-in">
                          {render_markdown(stream_text)}
                          <span :if={!stream_done} class="stream-cursor" aria-hidden="true"></span>
                        </div>
                        <%!-- Answer text is final but citations + verdict are
                              still streaming/being checked — without this the
                              finished-looking text just sits there until
                              :ask_complete swaps everything in. --%>
                        <div :if={stream_done} class="cite-pending">
                          <span class="voice-loader__spinner" aria-hidden="true"></span>
                          <span>Gathering rulebook citations…</span>
                        </div>
                      <% thinking? || voicing? -> %>
                        <% v_def = v_sel != "neutral" && Enum.find(@voices, &(&1.id == v_sel)) %>
                        <div class="answer-in">
                          <%!-- Voice in the id so switching persona mid-wait replaces
                                the ignored element — remounting the hook with the new
                                persona's phrases and label. The id is shared across
                                the thinking → voicing stages so the loader (and its
                                phrase cycle) persists seamlessly between them. --%>
                          <div
                            class="voice-loader"
                            id={"voice-loader-#{msg[:id]}-#{v_sel}"}
                            phx-hook="VoiceLoader"
                            phx-update="ignore"
                            data-phrases={
                              Jason.encode!(RuleMaven.Voices.loading_phrases(v_sel, @game))
                            }
                            data-stage={
                              if(voicing?,
                                do: "voicing",
                                else: Map.get(@ask_stage, msg[:id], "understanding")
                              )
                            }
                          >
                            <div :if={v_def} class="voice-loader__persona">
                              <span
                                :if={String.starts_with?(v_sel, "g:")}
                                aria-hidden="true"
                                class="voice-loader__persona-star"
                              >✦</span>
                              <span aria-hidden="true">{v_def.emoji}</span>
                              <span>{v_def.label} ANSWERING…</span>
                            </div>
                            <div class="voice-loader__row">
                              <span class="voice-loader__spinner" aria-hidden="true"></span>
                              <span class="voice-loader__phrase">Reticulating splines…</span>
                            </div>
                            <div class="voice-loader__bar">
                              <div class="voice-loader__fill"></div>
                            </div>
                          </div>
                        </div>
                      <% msg.role == :assistant && msg.content == "Thinking..." -> %>
                        <div style="font-size:0.6rem;opacity:0.5;margin-bottom:0.1rem;color:var(--text-muted)">
                          No answer received
                        </div>
                      <% true -> %>
                        <div class="answer-in">
                          {render_markdown(v_content || msg.content)}
                        </div>
                    <% end %>
                  </div>

                  <%= if msg.content != "Thinking..." do %>
                    <%= for c <- citation_list(msg) do %>
                      <% on_user = msg.role == :user %>
                      <figure
                        data-tour={if !on_user, do: "citation"}
                        style={"margin:0.75rem 0 0;border-radius:0.5rem;overflow:hidden;border:1px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 25%,transparent)", else: "var(--border)"};background:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 10%,transparent)", else: "var(--bg-subtle)"}"}
                      >
                        <%= if c["page"] do %>
                          <figcaption style={"display:flex;align-items:center;gap:0.35rem;padding:0.3rem 0.6rem;font-size:0.66rem;font-weight:700;letter-spacing:0.02em;text-transform:uppercase;border-bottom:1px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 15%,transparent)", else: "var(--border-subtle)"};color:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 85%,transparent)", else: "var(--text-muted)"}"}>
                            <span aria-hidden="true">&#128206;</span>
                            {c["source"] || "Rulebook"} &middot; p.{c["page"]}
                          </figcaption>
                        <% end %>
                        <blockquote style={"margin:0;padding:0.55rem 0.7rem 0.55rem 0.85rem;border-left:3px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 50%,transparent)", else: "var(--accent)"};font-style:italic;font-size:0.78rem;line-height:1.5;word-break:break-word;color:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 92%,transparent)", else: "var(--text)"}"}>
                          {render_markdown(String.trim(c["quote"] || ""))}
                        </blockquote>
                      </figure>
                    <% end %>
                  <% end %>

                  <!-- House-rule overlay: the user's own checked rules that embed near
                       this question. The RAW answer above stays canonical (and cache-
                       shared); house-rule flavor renders per-user underneath. -->
                  <%= if msg.role == :assistant && msg.id == @active_thread_id &&
                         @hr_overlay != [] && !msg[:refused] && !msg[:pending] &&
                         msg.content != "Thinking..." do %>
                    <.house_rule_overlay
                      rules={@hr_overlay}
                      deltas={@hr_overlay_deltas}
                      pending={@hr_delta_pending}
                      failed={@hr_delta_failed}
                    />
                  <% end %>

                  <!-- Related questions: followups (refine) + also-asked (separate) merged -->
                  <% has_followups = msg.role == :assistant && msg[:followups] not in [nil, []] %>
                  <% has_also = msg.role == :assistant && msg[:also_asked] not in [nil, []] %>
                  <%= if has_followups || has_also do %>
                    <div
                      data-tour="related"
                      style="margin-top:0.75rem;padding:0.6rem 0.75rem;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.5rem"
                    >
                      <div style="color:var(--text-muted);font-weight:600;margin-bottom:0.4rem;font-size:0.72rem">
                        Related questions
                      </div>
                      <div style="display:flex;flex-direction:column;gap:0.3rem">
                        <%= if has_followups do %>
                          <button
                            :for={q <- msg[:followups]}
                            type="button"
                            phx-click="ask_suggestion"
                            phx-value-q={q}
                            disabled={@pending_count >= @max_concurrent}
                            style="display:block;width:100%;box-sizing:border-box;text-align:left;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.35rem;padding:0.3rem 0.5rem;font-size:0.8rem;color:var(--text);cursor:pointer;line-height:1.35;white-space:normal;overflow-wrap:anywhere"
                          >{q}</button>
                        <% end %>
                        <%= if has_also do %>
                          <button
                            :for={q <- msg[:also_asked]}
                            type="button"
                            phx-click="quick_ask"
                            phx-value-question={q}
                            disabled={@pending_count >= @max_concurrent}
                            style="display:block;width:100%;box-sizing:border-box;text-align:left;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.35rem;padding:0.3rem 0.5rem;font-size:0.8rem;color:var(--text);cursor:pointer;line-height:1.35;white-space:normal;overflow-wrap:anywhere"
                          >{q}</button>
                        <% end %>
                      </div>
                    </div>
                  <% end %>

                  <!-- Refusal: suggest other questions -->
                  <%= if msg.role == :assistant && msg[:refused] do %>
                    <div style="margin-top:0.5rem;padding:0.5rem;background:var(--bg-subtle);border-radius:0.4rem;font-size:0.7rem;color:var(--text-secondary);line-height:1.5">
                      Try asking about:
                      <div style="margin-top:0.3rem;display:flex;flex-wrap:wrap;gap:0.25rem">
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="What is the setup?"
                          disabled={@pending_count >= @max_concurrent}
                          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                        >Setup</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="How do turns work?"
                          disabled={@pending_count >= @max_concurrent}
                          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                        >Turn order</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="How does scoring work?"
                          disabled={@pending_count >= @max_concurrent}
                          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                        >Scoring</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="What are the win conditions?"
                          disabled={@pending_count >= @max_concurrent}
                          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                        >Win conditions</button>
                      </div>
                    </div>
                  <% end %>

                  <!-- Refusal report: lets a player flag a wrong "not covered" so
                       an admin can review — reuses flag_question, which also
                       fetches a fresh (skip_pool) answer for the reporter.
                       Admins don't report (they ARE the reviewers); they get a
                       direct regenerate instead. -->
                  <%= if msg.role == :assistant && msg[:refused] && msg.content != "Thinking..." do %>
                    <div style="margin-top:0.4rem">
                      <%= if @is_admin do %>
                        <button
                          type="button"
                          phx-click="regenerate_answer"
                          phx-value-id={msg.id}
                          data-confirm="Regenerate a fresh answer for this wrongly refused question?"
                          style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted)"
                          title="Wrongly marked 'not covered' — fetch a fresh answer"
                        >↻ Regenerate — wrongly refused</button>
                      <% else %>
                        <%= if MapSet.member?(@flagged_ids, msg[:id]) do %>
                          <span style="font-size:0.65rem;color:var(--text-muted)">
                            ✓ Reported — thanks
                          </span>
                        <% else %>
                          <button
                            type="button"
                            phx-click="flag_question"
                            phx-value-id={msg.id}
                            data-confirm="Report this as wrongly marked 'not covered'? A moderator will review it, and we'll fetch you a fresh answer."
                            style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted)"
                            title="This should be covered by the rulebook"
                          >🚩 Report as miscategorized</button>
                        <% end %>
                      <% end %>
                    </div>
                  <% end %>

                  <!-- Pool hit badge. Both variants carry the mismatch escape
                       hatch: a trusted community answer can still be the wrong
                       MATCH for this question (distinct from being a bad
                       answer, which is what regenerate/votes cover), so the
                       button is not gated on can_regen. -->
                  <div
                    :if={msg[:pool_hit] && !msg[:pool_provisional]}
                    style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:var(--blue)"
                  >
                    💬 Community answer &mdash; from question pool
                  </div>
                  <div
                    :if={msg[:pool_hit] && msg[:pool_provisional]}
                    style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:var(--text-muted)"
                  >
                    🔎 Unverified answer &mdash; single source, not yet community-reviewed.
                    Vote below to help, or regenerate a fresh answer.
                  </div>
                  <div :if={msg[:pool_hit]} style="margin-top:0.35rem">
                    <button
                      type="button"
                      phx-click="not_my_question"
                      phx-value-id={msg.id}
                      data-confirm="This answer matched a similar question, not yours? We'll fetch a fresh answer for exactly what you asked."
                      style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted)"
                      title="This matched a different question — get a fresh answer to yours"
                    >🙋 Not my question — ask fresh</button>
                  </div>

                  <%!-- Player-facing affordance for failed ("⚠️ ...") answers.
                        Admins get their own re-ask row below; refused/blocked
                        rows and the kill-switch "paused" notice stay dead-ended
                        on purpose. Kind decides the affordance: bounded retry,
                        cooldown note for rate limits, shorten-hint for
                        too-long, auto-report notice once retries run out. --%>
                  <% err_kind = msg[:error_kind] %>
                  <% err_retries = msg[:error_retries] || 0 %>
                  <% retryable_kind? = is_nil(err_kind) || err_kind not in ["paused", "too_long"] %>
                  <div
                    :if={
                      !@is_admin && msg.role == :assistant && !msg[:pending] && !msg[:history] &&
                        !msg[:refused] && is_binary(msg.content) &&
                        String.starts_with?(msg.content, "⚠️") && err_kind != "paused"
                    }
                    style="margin-top:0.5rem;display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap"
                  >
                    <%= cond do %>
                      <% err_kind == "too_long" -> %>
                        <span style="font-size:0.72rem;color:var(--text-muted)">
                          Try asking a shorter question.
                        </span>
                      <% retryable_kind? && err_retries < Games.error_retry_limit() -> %>
                        <button
                          type="button"
                          phx-click="retry_question"
                          phx-value-id={msg.id}
                          disabled={@pending_count >= @max_concurrent}
                          style="background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.7rem;cursor:pointer;padding:0.15rem 0.55rem;color:var(--text)"
                          title="Try this question again"
                        >↻ Retry</button>
                        <span
                          :if={err_kind == "rate_limited"}
                          style="font-size:0.7rem;color:var(--text-muted)"
                        >Give it ~30 seconds first.</span>
                      <% err_kind && err_retries >= Games.error_retry_limit() -> %>
                        <span style="font-size:0.72rem;color:var(--text-muted)">
                          🚩 Still failing after retries — this has been reported to the admins.
                        </span>
                      <% true -> %>
                        <span style="font-size:0.72rem;color:var(--text-muted)">
                          This keeps failing. Please try again later.
                        </span>
                    <% end %>
                  </div>

                  <% is_community_msg =
                    MapSet.member?(MapSet.new(@community_questions, & &1.id), msg[:id]) %>

                  <!-- Answer actions: voice switcher + vote + overflow, one row.
                       Lives INSIDE the bubble (not a sibling below it) so it
                       stretches to the bubble's actual rendered width instead
                       of shrink-wrapping its own content — the outer chat-msg
                       column uses align-items:flex-start, which sizes each
                       sibling independently. -->
                  <div
                    :if={
                      msg.role == :assistant && !msg[:refused] &&
                        msg.content != "Thinking..." && !msg[:pending] &&
                        not String.starts_with?(msg.content, "⚠️")
                    }
                    style="display:flex;flex-wrap:wrap;gap:0.5rem;align-items:center;margin-top:0.5rem"
                  >
                    <% q_text = find_question_for_answer(@conversation, msg) %>
                    <% plain_text = strip_markdown(msg.content) %>
                    <% can_regen =
                      cond do
                        is_community_msg ->
                          false

                        msg[:pool_hit] && msg[:pool_source_id] ->
                          msg[:pool_provisional] &&
                            (@is_admin or
                               Map.get(@community_user_votes, msg[:pool_source_id]) != "up")

                        !msg[:pool_hit] ->
                          @is_admin or Map.get(@community_user_votes, msg[:id]) != "up"

                        true ->
                          false
                      end %>

                    <!-- Community vote buttons (primary action, kept inline) -->
                    <%= if is_community_msg do %>
                      <% cv = Map.get(@community_user_votes, msg[:id]) %>
                      <% counts = Map.get(@community_vote_counts, msg[:id], %{up: 0, down: 0}) %>
                      <span
                        data-tour="answer-vote"
                        style="display:inline-flex;align-items:center;gap:0.15rem"
                      >
                        <button
                          type="button"
                          phx-click="community_vote"
                          phx-value-id={msg[:id]}
                          phx-value-vote="up"
                          style={"background:none;border:none;padding:0;line-height:1;cursor:pointer;display:inline-flex;color:#{if cv == "up", do: "var(--accent)", else: "var(--text-muted)"}"}
                          title={if cv == "up", do: "Remove vote", else: "Helpful"}
                        ><.icon
                          name={
                            if cv == "up", do: "hero-hand-thumb-up-solid", else: "hero-hand-thumb-up"
                          }
                          class="size-4"
                        /></button>
                        <span
                          style="font-size:0.65rem;color:var(--text-muted)"
                          title="Total helpful votes"
                        >{Map.get(counts, :up, 0)}</span>
                        <span
                          :if={MapSet.member?(@asker_confirmed_ids, msg[:id])}
                          style="font-size:0.6rem;color:var(--accent);border:1px solid currentColor;border-radius:0.5rem;padding:0 0.35rem;line-height:1.4;white-space:nowrap"
                          title="Count includes the asker, who confirmed this answered their question"
                        >✓ asker</span>
                      </span>
                    <% else %>
                      <%= if msg[:pool_hit] && msg[:pool_source_id] do %>
                        <!-- Pool hit (trusted or provisional): vote accrues to the
                           source row, so every player sees the same tally. -->
                        <% sid = msg[:pool_source_id] %>
                        <% cv = Map.get(@community_user_votes, sid) %>
                        <% counts = Map.get(@community_vote_counts, sid, %{up: 0, down: 0}) %>
                        <span
                          data-tour="answer-vote"
                          style="display:inline-flex;align-items:center;gap:0.15rem"
                        >
                          <button
                            type="button"
                            phx-click="community_vote"
                            phx-value-id={sid}
                            phx-value-vote="up"
                            style={"background:none;border:none;padding:0;line-height:1;cursor:pointer;display:inline-flex;color:#{if cv == "up", do: "var(--accent)", else: "var(--text-muted)"}"}
                            title={if cv == "up", do: "Remove vote", else: "Helpful"}
                          ><.icon
                            name={
                              if cv == "up",
                                do: "hero-hand-thumb-up-solid",
                                else: "hero-hand-thumb-up"
                            }
                            class="size-4"
                          /></button>
                          <span
                            style="font-size:0.65rem;color:var(--text-muted)"
                            title="Total helpful votes"
                          >{Map.get(counts, :up, 0)}</span>
                          <span
                            :if={MapSet.member?(@asker_confirmed_ids, sid)}
                            style="font-size:0.6rem;color:var(--accent);border:1px solid currentColor;border-radius:0.5rem;padding:0 0.35rem;line-height:1.4;white-space:nowrap"
                            title="Count includes the asker, who confirmed this answered their question"
                          >✓ asker</span>
                        </span>
                      <% else %>
                        <!-- Own (non-pool) answer: votes go to the same QuestionVote
                           store as community/pool answers, so the asker's thumb and
                           every other player's vote sum into one per-user tally
                           (was a separate scalar `feedback` column that never
                           combined with other users' votes). -->
                        <% cv = Map.get(@community_user_votes, msg[:id]) %>
                        <% counts = Map.get(@community_vote_counts, msg[:id], %{up: 0, down: 0}) %>
                        <span
                          :if={!msg[:pool_hit]}
                          data-tour="answer-vote"
                          style="display:inline-flex;align-items:center;gap:0.15rem"
                        >
                          <%!-- This branch is always the asker's own question: the
                              thumb is a self-confirmation, stored at weight 0. It
                              counts in the visible tally (a click must increment
                              the number) and shows other users an "asker
                              confirmed" badge. --%>
                          <button
                            type="button"
                            phx-click="community_vote"
                            phx-value-id={msg[:id]}
                            phx-value-vote="up"
                            style={"background:none;border:none;padding:0;line-height:1;cursor:pointer;display:inline-flex;color:#{if cv == "up", do: "var(--accent)", else: "var(--text-muted)"}"}
                            title={
                              if cv == "up",
                                do: "Remove confirmation",
                                else: "Confirm this answered your question"
                            }
                          ><.icon
                            name={
                              if cv == "up",
                                do: "hero-hand-thumb-up-solid",
                                else: "hero-hand-thumb-up"
                            }
                            class="size-4"
                          /></button>
                          <span
                            style="font-size:0.65rem;color:var(--text-muted)"
                            title="Total helpful votes"
                          >{Map.get(counts, :up, 0)}</span>
                        </span>
                      <% end %>
                    <% end %>

                    <%!-- Everything else right-aligns in one group: category pills,
                        then the overflow menu. --%>
                    <span style="display:inline-flex;flex-wrap:wrap;align-items:center;gap:0.5rem;margin-left:auto">
                      <!-- Category pills. Categories live in the (community) FAQ, so
                       only show on community questions — except admins, who see
                       them on any answer to audit tagging before it goes
                       community. -->
                      <% msg_cats =
                        if (is_community_msg || @is_admin) && msg.role == :assistant && msg[:id],
                          do: Map.get(@question_categories, msg[:id], []),
                          else: [] %>
                      <span
                        :if={msg_cats != []}
                        style="display:inline-flex;flex-wrap:wrap;align-items:center;gap:0.25rem"
                      >
                        <span style="font-size:0.55rem;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-muted);font-weight:600">
                          Categories
                        </span>
                        <.link
                          :for={cat <- msg_cats}
                          navigate={
                            ~p"/games/#{@game}/community?category=#{RuleMaven.Hashid.encode(cat.id)}"
                          }
                          style="font-size:0.6rem;padding:0.1rem 0.4rem;border-radius:1rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-muted);text-decoration:none"
                        >
                          {cat.name}
                        </.link>
                      </span>

                      <!-- Overflow: secondary actions (favorite, copy, regenerate) -->
                      <details class="card-menu">
                        <summary class="card-menu__trigger" title="More actions">
                          ⋯
                        </summary>
                        <div class="card-menu__pop card-menu__pop--right card-menu__pop--up">
                          <%= if is_community_msg do %>
                            <%!-- Browsed community answer: favorite marks it for the
                              Community sidebar list, unrelated to thread order. --%>
                            <% fav? = MapSet.member?(@favorited_answer_ids, msg[:id]) %>
                            <button
                              type="button"
                              phx-click="favorite_community_answer"
                              phx-value-id={msg[:id]}
                              class="card-menu__item"
                              title={
                                if fav?,
                                  do: "Remove from your favorites",
                                  else: "Add to your favorites"
                              }
                            >{if fav?, do: "♥ Unfavorite", else: "♡ Favorite"}</button>
                          <% else %>
                            <%!-- Your own asked question (private or pool-served): pins
                              it to the top of the sidebar's thread list. --%>
                            <button
                              type="button"
                              phx-click="favorite_question"
                              phx-value-id={msg.id}
                              class="card-menu__item"
                              title={
                                if msg[:favorited],
                                  do: "Unfavorite",
                                  else: "Favorite — moves to top of your list"
                              }
                            >{if msg[:favorited], do: "♥ Unfavorite", else: "♡ Favorite"}</button>
                          <% end %>
                          <button
                            type="button"
                            id={"copy-btn-#{idx}"}
                            phx-hook="ClipboardCopy"
                            data-clipboard-text={"Q: #{q_text}\n\nA: #{plain_text}"}
                            class="card-menu__item"
                            title="Copy question and answer"
                          >📋 Copy Q&amp;A</button>
                          <button
                            :if={can_regen}
                            type="button"
                            phx-click="regenerate_answer"
                            phx-value-id={msg.id}
                            data-confirm="Regenerate this answer? The current one will be replaced."
                            class="card-menu__item"
                            title="Generate a fresh answer from the rulebook"
                          >↻ Regenerate</button>
                          <% flag_id = msg[:pool_source_id] || msg[:id] %>
                          <%= if flag_id && msg.content != "Thinking..." do %>
                            <%= if @is_admin do %>
                              <!-- Admins don't report (they ARE the moderators) —
                               direct pull from the pool instead. -->
                              <button
                                type="button"
                                phx-click="pull_for_review"
                                phx-value-id={msg.id}
                                data-confirm="Pull this answer from the shared pool for review? It stays out of the pool until re-approved."
                                class="card-menu__item"
                                title="Pull from the pool into the moderation queue"
                              >⏸ Pull for review</button>
                            <% else %>
                              <%= if MapSet.member?(@flagged_ids, flag_id) do %>
                                <button
                                  type="button"
                                  disabled
                                  class="card-menu__item"
                                  style="opacity:0.6;cursor:default"
                                  title="You reported this answer"
                                >✓ Reported</button>
                              <% else %>
                                <button
                                  type="button"
                                  phx-click="open_report"
                                  phx-value-id={msg.id}
                                  class="card-menu__item"
                                  title="Report a wrong or unhelpful answer"
                                >🚩 Report</button>
                              <% end %>
                            <% end %>
                          <% end %>
                        </div>
                      </details>
                    </span>
                  </div>

                  <!-- Message actions (admin only). Also inside the bubble (like
                     the row above) so it stretches to the bubble's own width
                     instead of shrink-wrapping — otherwise margin-left:auto on
                     the model-name span below has no room to push into. -->
                  <div
                    :if={RuleMaven.Users.can?(@current_user, :admin) && msg.role == :assistant}
                    class="flex items-center gap-1 mt-0.5"
                    style="flex-wrap:wrap;min-width:0;padding-left:0.25rem"
                  >
                    <%= if msg.content == "Thinking..." do %>
                      <button
                        type="button"
                        phx-click="retry_question"
                        phx-value-id={msg.id}
                        disabled={@pending_count >= @max_concurrent}
                        style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                        title="Re-ask"
                      >↻</button>
                      <%= if @confirm_delete_id == msg.id do %>
                        <span class="text-xs" style="color:var(--red)">Delete?</span>
                        <button
                          type="button"
                          phx-click="confirm_delete_question"
                          phx-value-id={msg.id}
                          style="color:var(--red);background:none;border:none;font-size:0.6rem;font-weight:600;cursor:pointer"
                        >Yes</button>
                        <button
                          type="button"
                          phx-click="cancel_delete_question"
                          style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                        >No</button>
                      <% else %>
                        <button
                          type="button"
                          phx-click="delete_question"
                          phx-value-id={msg.id}
                          style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                          title="Delete"
                        >✕</button>
                      <% end %>
                    <% else %>
                      <% is_error = is_binary(msg.content) && String.starts_with?(msg.content, "⚠️") %>
                      <%= if msg[:refused] || is_error do %>
                        <!-- error/refused: retry + delete only -->
                        <%= if is_error do %>
                          <button
                            type="button"
                            phx-click="retry_question"
                            phx-value-id={msg.id}
                            disabled={@pending_count >= @max_concurrent}
                            style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                            title="Re-ask"
                          >↻</button>
                        <% end %>
                        <%= if @confirm_delete_id == msg.id do %>
                          <span class="text-xs" style="color:var(--red)">Delete?</span>
                          <button
                            type="button"
                            phx-click="confirm_delete_question"
                            phx-value-id={msg.id}
                            style="color:var(--red);background:none;border:none;font-size:0.6rem;font-weight:600;cursor:pointer"
                          >Yes</button>
                          <button
                            type="button"
                            phx-click="cancel_delete_question"
                            style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                          >No</button>
                        <% else %>
                          <button
                            :if={!msg[:history]}
                            type="button"
                            phx-click="delete_question"
                            phx-value-id={msg.id}
                            style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                            title="Delete"
                          >✕</button>
                        <% end %>
                      <% else %>
                        <!-- normal answer: full actions. Re-ask is dropped here —
                           skip_pool:false just re-serves the same pooled
                           answer, so it's a no-op vs the overflow menu's
                           "Regenerate" (skip_pool:true, forces fresh). -->
                        <%!-- Demote-only: rows reach the community pool via vote
                            quorum or admin verify. A manual promote here would
                            render identically to a crowd-promoted row, passing
                            off an admin push as community consensus. --%>
                        <button
                          :if={
                            @is_admin && !msg[:history] && !msg[:pool_hit] &&
                              msg[:visibility] == "community"
                          }
                          type="button"
                          phx-click="toggle_question_visibility"
                          phx-value-id={msg.id}
                          title="Remove from community (make private)"
                          style="background:none;border:none;font-size:0.6rem;cursor:pointer;color:var(--accent-ink,var(--accent))"
                        >🌐</button>
                        <%!-- Favorite/pin-to-top moved to the main action row
                            (visible to all users, not just admins). --%>
                        <button
                          :if={!msg[:history]}
                          type="button"
                          phx-click="verify_question"
                          phx-value-id={msg.id}
                          style={"background:none;border:none;font-size:0.6rem;cursor:pointer;#{if msg[:verified], do: "color:#15803d", else: "color:var(--text-muted)"}"}
                          title={
                            if msg[:verified],
                              do: "Admin-verified & published — click to unpublish",
                              else: "Verify & publish to community (admin)"
                          }
                        >{if msg[:verified], do: "✔", else: "✓"}</button>
                        <%= if @confirm_delete_id == msg.id do %>
                          <span class="text-xs" style="color:var(--red)">{if msg[:pending],
                            do: "Cancel?",
                            else: "Delete?"}</span>
                          <button
                            type="button"
                            phx-click="confirm_delete_question"
                            phx-value-id={msg.id}
                            style="color:var(--red);background:none;border:none;font-size:0.6rem;font-weight:600;cursor:pointer"
                          >Yes</button>
                          <button
                            type="button"
                            phx-click="cancel_delete_question"
                            style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                          >No</button>
                        <% else %>
                          <button
                            :if={!msg[:history]}
                            type="button"
                            phx-click="delete_question"
                            phx-value-id={msg.id}
                            style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                            title={if msg[:pending], do: "Cancel", else: "Delete"}
                          >✕</button>
                        <% end %>
                        <%= if RuleMaven.Users.can?(@current_user, :admin) && (msg[:llm_provider] || msg[:llm_model]) do %>
                          <span
                            class="text-xs"
                            style="color:var(--text-muted);margin-left:auto;min-width:0;overflow-wrap:anywhere;word-break:break-word;text-align:right"
                          >{msg[
                            :llm_provider
                          ]} &middot; {msg[:llm_model]}</span>
                        <% end %>
                      <% end %>
                    <% end %>
                    <!-- Admin debug: raw LLM response -->
                    <details
                      :if={
                        RuleMaven.Users.can?(@current_user, :admin) && msg.role == :assistant &&
                          msg[:raw_response] && msg.content != "Thinking..."
                      }
                      style="margin:0;font-size:0.6rem;color:var(--text-muted);opacity:0.6"
                    >
                      <summary style="cursor:pointer">raw</summary>
                      <pre style="white-space:pre-wrap;word-break:break-word;margin-top:0.15rem;padding:0.25rem 0.5rem;background:var(--bg-subtle);border-radius:0.25rem;max-height:12rem;overflow-y:auto"><%= msg[:raw_response] %></pre>
                    </details>
                    <!-- Admin-only: version history (prior deleted regenerate/report
                       versions of this Q&A — see Audit.question_history/2) -->
                    <% q_text_hist =
                      if @is_admin && msg.role == :assistant && !msg[:history] &&
                           msg.content != "Thinking...",
                         do: find_question_for_answer(@conversation, msg) %>
                    <button
                      :if={
                        @is_admin && msg.role == :assistant && !msg[:history] &&
                          msg.content != "Thinking..."
                      }
                      type="button"
                      phx-click="toggle_question_history"
                      phx-value-id={msg.id}
                      phx-value-question={q_text_hist}
                      style="margin:0;color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer;text-align:left"
                    >{if MapSet.member?(@history_open, msg.id), do: "▾", else: "▸"} History</button>
                    <!-- Admin-only: LLM trace (every llm_logs call recorded for
                       this question — see LLM.calls_for_question/1) -->
                    <button
                      :if={
                        @is_admin && msg.role == :assistant && !msg[:history] &&
                          msg.content != "Thinking..."
                      }
                      type="button"
                      phx-click="toggle_llm_trace"
                      phx-value-id={msg.id}
                      style="margin:0;color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer;text-align:left"
                    >{if MapSet.member?(@llm_trace_open, msg.id), do: "▾", else: "▸"} LLM trace</button>
                  </div>
                  <%= if @is_admin && msg.role == :assistant && !msg[:history] && msg.content != "Thinking..." do %>
                    <div
                      :if={MapSet.member?(@history_open, msg.id)}
                      style="margin-top:0.25rem;padding:0.4rem 0.6rem;border:1px solid var(--border);border-radius:0.4rem;background:var(--bg-subtle);display:flex;flex-direction:column;gap:0.4rem"
                    >
                      <% history = Map.get(@question_history, msg.id, []) %>
                      <%= if history == [] do %>
                        <span style="font-size:0.65rem;color:var(--text-muted)">No prior versions.</span>
                      <% else %>
                        <%= for entry <- history do %>
                          <div style="font-size:0.65rem;color:var(--text-muted);border-bottom:1px solid var(--border);padding-bottom:0.35rem">
                            <div style="font-weight:600;color:var(--text-secondary)">
                              {entry.inserted_at |> Calendar.strftime("%Y-%m-%d %H:%M UTC")} &middot; {entry.actor_username ||
                                "system"} &middot; {entry.metadata["via"] || "system"}
                            </div>
                            <div style="margin-top:0.15rem;white-space:pre-wrap;word-break:break-word">
                              {entry.metadata["answer"]}
                            </div>
                            <div style="margin-top:0.15rem;opacity:0.8">
                              👍 {entry.metadata["upvotes"] || 0} &middot; 👎 {entry.metadata[
                                "downvotes"
                              ] || 0}
                              {if entry.metadata["pooled"], do: " · pooled"}
                              {if entry.metadata["needs_review"], do: " · pulled for review"}
                              {if entry.metadata["verified"], do: " · verified"}
                            </div>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                    <div
                      :if={MapSet.member?(@llm_trace_open, msg.id)}
                      style="margin-top:0.25rem;padding:0.4rem 0.6rem;border:1px solid var(--border);border-radius:0.4rem;background:var(--bg-subtle);display:flex;flex-direction:column;gap:0.3rem"
                    >
                      <% trace = Map.get(@llm_traces, msg.id, %{calls: [], totals: nil}) %>
                      <%= if trace.calls == [] do %>
                        <span style="font-size:0.65rem;color:var(--text-muted)">
                          No LLM calls recorded — served from cache, or asked before call tracing existed.
                        </span>
                      <% else %>
                        <div style="font-size:0.65rem;font-weight:600;color:var(--text-secondary)">
                          {trace.totals.count} call{if trace.totals.count != 1, do: "s"} &middot; {format_trace_cost(
                            trace.totals.cost
                          )} &middot; {format_trace_duration(trace.totals.duration_ms)} &middot; {trace.totals.tokens} tokens
                        </div>
                        <%= for call <- trace.calls do %>
                          <div style="font-size:0.65rem;color:var(--text-muted);border-top:1px solid var(--border);padding-top:0.25rem;display:flex;flex-wrap:wrap;gap:0.15rem 0.45rem;align-items:baseline">
                            <span style="font-variant-numeric:tabular-nums">{Calendar.strftime(
                              call.inserted_at,
                              "%H:%M:%S"
                            )}</span>
                            <span style="font-weight:600;color:var(--text-secondary)">{call.operation}</span>
                            <span style="overflow-wrap:anywhere">{call.model}</span>
                            <span :if={call.total_tokens}>
                              {call.prompt_tokens || 0}→{call.completion_tokens || 0} tok
                            </span>
                            <span>{format_trace_cost(call.cost)}</span>
                            <span>{format_trace_duration(call.duration_ms)}</span>
                            <span style={"color:#{if call.success, do: "var(--success, #16a34a)", else: "var(--danger, #dc2626)"}"}>
                              {if call.success, do: "✓", else: "✗"}
                            </span>
                            <span
                              :if={call.detail["cached_tokens"]}
                              title="provider-cached prompt tokens"
                            >
                              ⚡{call.detail["cached_tokens"]} cached
                            </span>
                            <span :if={call.detail["reasoning_effort"]}>
                              🧠 {call.detail["reasoning_effort"]}
                            </span>
                            <span
                              :if={call.detail["finish_reason"] not in [nil, "stop", "end_turn"]}
                              style="color:var(--warning, #d97706)"
                              title="model stopped before a natural end"
                            >
                              ⚠ {call.detail["finish_reason"]}
                            </span>
                            <span
                              :if={call.detail["truncation_retry"]}
                              style="color:var(--warning, #d97706)"
                              title="retry of a truncated call with a doubled token cap"
                            >
                              ↻ retry
                            </span>
                            <span
                              :if={!call.success && call.error_message}
                              title={call.error_message}
                              style="flex-basis:100%;overflow-wrap:anywhere;opacity:0.8"
                            >
                              {String.slice(call.error_message, 0, 200)}
                            </span>
                            <details
                              :if={call.detail["input"] || call.detail["output"]}
                              style="flex-basis:100%;margin:0"
                            >
                              <summary style="cursor:pointer;opacity:0.8;font-size:0.62rem">
                                in/out
                              </summary>
                              <div :if={call.detail["input"]} style="margin-top:0.25rem">
                                <div style="font-weight:600;color:var(--text-secondary)">→ in</div>
                                <pre style="margin:0.1rem 0 0;padding:0.3rem 0.45rem;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.3rem;white-space:pre-wrap;word-break:break-word;font-size:0.62rem;max-height:12rem;overflow-y:auto">{call.detail["input"]}</pre>
                              </div>
                              <div :if={call.detail["output"]} style="margin-top:0.25rem">
                                <div style="font-weight:600;color:var(--text-secondary)">← out</div>
                                <pre style="margin:0.1rem 0 0;padding:0.3rem 0.45rem;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.3rem;white-space:pre-wrap;word-break:break-word;font-size:0.62rem;max-height:12rem;overflow-y:auto">{call.detail["output"]}</pre>
                              </div>
                            </details>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
            <!-- end history else -->
          <% end %>
        </div>
      </div>

      <%!-- Report-reason modal: pick why the answer is being reported. --%>
      <ReportModal.report_modal :if={@report_target} />

      <%!-- Suggested-questions modal. Backdrop closes via phx-click-away on the
            panel; picking a question asks it and closes (ask_suggestion). --%>
      <div
        :if={@suggestions_modal}
        style="position:fixed;top:0;left:0;right:0;bottom:var(--jobpanel-h, 0px);z-index:60;background:rgba(0,0,0,0.45);display:flex;align-items:flex-end;justify-content:center;padding:1rem"
      >
        <div
          phx-click-away="close_suggestions"
          phx-window-keydown="close_suggestions"
          phx-key="Escape"
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;max-width:42rem;width:100%;max-height:70vh;overflow-y:auto;box-shadow:0 10px 40px rgba(0,0,0,0.3)"
        >
          <div style="display:flex;align-items:center;justify-content:space-between;padding:0.85rem 1rem;border-bottom:1px solid var(--border);position:sticky;top:0;background:var(--bg-surface);z-index:1">
            <div style="font-size:0.95rem;font-weight:700;color:var(--text)">Suggested questions</div>
            <button
              type="button"
              phx-click="close_suggestions"
              aria-label="Close"
              style="background:none;border:none;font-size:1.1rem;cursor:pointer;color:var(--text-muted);line-height:1"
            >✕</button>
          </div>
          <div style="padding:0.85rem 1rem;display:flex;flex-direction:column;gap:1rem">
            <%= for cat <- @suggestions do %>
              <div>
                <div style="font-size:0.72rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;margin-bottom:0.35rem">
                  {cat.category}
                </div>
                <div style="display:flex;flex-direction:column;gap:0.3rem">
                  <%= for q <- cat.questions do %>
                    <button
                      type="button"
                      phx-click="ask_suggestion"
                      phx-value-q={q}
                      disabled={@pending_count >= @max_concurrent}
                      style="text-align:left;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.45rem 0.7rem;font-size:0.82rem;color:var(--text);cursor:pointer;white-space:normal;word-break:break-word;line-height:1.45"
                    >{q}</button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Input -->
      <div
        class="chat-input"
        style="flex-shrink:0;padding:0.35rem 1rem 0.5rem 1rem;border-top:1px solid var(--border);background:var(--bg-surface);position:relative;z-index:1"
      >
        <div style="max-width:48rem;margin:0 auto;width:100%">
          <%= if length(@expansions) > 0 do %>
            <div
              data-tour="expansions"
              style="display:flex;flex-wrap:wrap;gap:0.35rem;margin-bottom:0.35rem"
            >
              <span style="font-size:0.65rem;color:var(--text-muted);font-weight:600;align-self:center">Include:</span>
              <%= for exp <- @expansions do %>
                <label style={"cursor:pointer;font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:0.3rem;#{if Map.get(@included_expansions, exp.id), do: "background:var(--accent);color:var(--accent-text,#fff)", else: "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border)"}"}>
                  <input
                    type="checkbox"
                    checked={Map.get(@included_expansions, exp.id)}
                    phx-click="toggle_expansion"
                    phx-value-id={exp.id}
                    style="display:none"
                  />
                  {exp.name}
                </label>
              <% end %>
            </div>
          <% end %>
          <div
            :if={@asks_disabled}
            style="margin-bottom:0.5rem;padding:0.5rem 0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:color-mix(in srgb,var(--danger,#c0392b) 8%,transparent);color:var(--text);font-size:0.78rem"
          >
            ⏸️ {RuleMaven.Settings.asks_disabled_message()}{if @is_admin,
              do: " (You can still ask as an admin.)"}
          </div>
          <%!-- Not-yet-Ready gate: users can't ask until the game is published;
                admins can, to test it. --%>
          <div
            :if={not @game.playable}
            style="margin-bottom:0.5rem;padding:0.5rem 0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:color-mix(in srgb,var(--yellow) 10%,transparent);color:var(--text);font-size:0.78rem"
          >
            🧪 Not yet marked Ready — you're testing as admin.
          </div>
          <%!-- Above-the-box controls: open the suggested-questions modal (left)
                and pick the default answer voice (right). The voice applies to
                every answer and persists in localStorage via VoiceDefault. --%>
          <% cur_default = Enum.find(@voices, &(&1.id == @default_voice)) || hd(@voices) %>
          <div style="display:flex;align-items:center;gap:0.5rem;margin-bottom:0.35rem">
            <button
              :if={@suggestions != []}
              type="button"
              phx-click="open_suggestions"
              data-tour="suggestions"
              style="display:inline-flex;align-items:center;gap:0.3rem;font-size:0.7rem;font-weight:600;color:var(--accent);background:none;border:none;cursor:pointer;padding:0"
            >
              <span aria-hidden="true">💡</span> Suggested questions
            </button>
            <div
              data-tour="voices"
              style="display:flex;align-items:center;gap:0.4rem;margin-left:auto"
            >
              <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">Answer persona</span>
              <details class="card-menu">
                <summary style="font-size:0.68rem;color:var(--text);font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.55rem;background:var(--bg-surface);cursor:pointer;list-style:none">
                  <span aria-hidden="true">{cur_default.emoji}</span>
                  <span>{cur_default.label}</span>
                  <span style="opacity:0.6">▾</span>
                </summary>
                <.voice_menu
                  voices={@voices}
                  game_name={@game.name}
                  current={@default_voice}
                  event="set_default_voice"
                  up={true}
                />
              </details>
            </div>
          </div>
          <form phx-submit="ask" class="flex gap-2" phx-hook="KeyboardSubmit" id="ask-form">
            <button
              type="button"
              id="voice-ask-btn"
              phx-hook="VoiceDictation"
              data-target="ask-input"
              data-autosubmit="true"
              title="Ask by voice"
              disabled={
                @pending_count >= @max_concurrent || @source_count == 0 ||
                  (not @game.playable and not @is_admin)
              }
              style="flex-shrink:0;background:none;border:1px solid var(--border);border-radius:2rem;padding:0.4rem 0.6rem;cursor:pointer;font-size:0.85rem;color:var(--text-muted)"
            >🎤</button>
            <input
              type="text"
              name="question"
              value={@question}
              placeholder={
                if @source_count > 0,
                  do: "Ask a rules question…",
                  else: "Add rulebook text to start asking..."
              }
              maxlength={600}
              class="flex-1 border rounded-full px-4 py-2.5 text-sm"
              style="background:var(--bg);color:var(--text);border-color:var(--border-strong)"
              disabled={
                @pending_count >= @max_concurrent || @source_count == 0 ||
                  (not @game.playable and not @is_admin)
              }
              autocomplete="off"
              id="ask-input"
              phx-hook="FocusInput"
            />
            <input type="hidden" name="visibility" value={@visibility} />
            <button
              type="submit"
              disabled={
                @pending_count >= @max_concurrent || @source_count == 0 ||
                  (not @game.playable and not @is_admin)
              }
              style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.5rem 1.25rem;border-radius:2rem;font-weight:600;font-size:0.85rem;cursor:pointer"
            >
              {if @pending_count >= @max_concurrent, do: "Wait…", else: "Send"}
            </button>
          </form>
          <%= if @pending_count >= @max_concurrent do %>
            <div style="text-align:center;font-size:0.72rem;color:var(--text-muted);margin-top:0.3rem">
              {@pending_count} of {@max_concurrent} questions in progress — please wait for one to finish
            </div>
          <% end %>
          <%!-- Always-visible AI disclaimer: answers come from an LLM and can be
                wrong, so keep the caveat in sight on every ask. --%>
          <div style="text-align:center;font-size:0.68rem;line-height:1.3;color:var(--text-muted);margin-top:0.3rem">
            🤖 AI with strict guardrails — answers are grounded in the rulebook and cite their sources. AI can still be wrong: double-check important rulings. Answered questions may be shared anonymously in the Community Q&A.
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ──

  # Pair consecutive user→assistant messages, ignore history/refused entries.
  # Returns last 2 valid Q&A pairs for followup context.
  defp build_recent_pairs(msgs) do
    msgs
    |> Enum.zip(Enum.drop(msgs, 1))
    |> Enum.filter(fn {a, b} -> a.role == :user && b.role == :assistant end)
    |> Enum.map(fn {user, asst} -> %{q: user.content, a: asst.content} end)
    |> Enum.take(-2)
  end

  defp find_question_for_answer(conversation, assistant_msg) do
    {_, question} =
      Enum.reduce(conversation, {false, ""}, fn msg, {found, q} ->
        cond do
          msg == assistant_msg -> {true, q}
          found -> {true, q}
          msg.role == :user -> {false, msg.content}
          true -> {false, q}
        end
      end)

    question
  end

  # LLM-trace panel formatting. Costs are fractions of a cent per call, so four
  # decimal places; sub-cent totals still render as non-zero.
  defp format_trace_cost(cost) when is_number(cost),
    do: "$#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"

  defp format_trace_cost(_), do: "$—"

  defp format_trace_duration(ms) when is_integer(ms) and ms >= 1000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_trace_duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_trace_duration(_), do: "—"

  defp strip_markdown(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/^[-*]\s+/m, "")
  end

  # True if any voice restyle is in flight for this question (regardless of
  # which persona), so the sidebar dot lights up during a persona switch too.
  defp restyling?(nil, _id), do: false

  defp restyling?(voice_pending, id) do
    Enum.any?(voice_pending, fn {ql_id, _voice} -> ql_id == id end)
  end

  # One sidebar row: shared by the Favorites section and each time group
  # (Today/Last 7 Days/Older) so the two render identically.
  attr :t, :map, required: true
  attr :active_thread_id, :any, required: true
  attr :show_asker, :boolean, default: false
  attr :voice_pending, :any, default: nil

  defp thread_sidebar_item(assigns) do
    ~H"""
    <%!-- id carries the favorited flag: a toggle moves this row into a
          different section (Favorites <-> the time groups), and folding
          favorited into the id forces LiveView to unmount/remount the node
          instead of relocating the existing one, so the CSS entrance
          animation (.sidebar-item) fires the same way in both directions. --%>
    <button
      id={"thread-#{@t.id}-#{@t.favorited}"}
      type="button"
      class="sidebar-item"
      phx-click="switch_thread"
      phx-value-id={@t.id}
      style={"display:block;text-align:left;border:none;cursor:pointer;padding:0.22rem 0.75rem;font-size:0.73rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == @t.id, do: "var(--accent)", else: "transparent"};width:100%;color:var(--text)"}
    >
      <div style="display:flex;align-items:baseline;gap:0.2rem">
        <span :if={@t.favorited} style="color:#e05c2a;font-size:0.55rem;flex-shrink:0">♥</span>
        <span
          :if={@t.pending || restyling?(@voice_pending, @t.id)}
          class="animate-pulse"
          style="color:var(--accent-ink,var(--accent));font-size:0.45rem;flex-shrink:0"
        >●</span>
        <span
          :if={!@t.pending && is_binary(@t.answer) && String.starts_with?(@t.answer, "⚠️")}
          style="color:var(--red,#e53e3e);font-size:0.55rem;flex-shrink:0"
          title="Failed"
        >⚠</span>
        <span
          :if={@t.refused}
          style="color:var(--text-muted);font-size:0.55rem;flex-shrink:0"
          title="Not covered by the rules"
        >🚫</span>
        <span style="word-break:break-word;white-space:normal">
          <span
            :if={@show_asker}
            style="color:var(--text-muted);font-weight:600;font-size:0.62rem;margin-right:0.25rem"
          >{@t.asker}:</span>{@t.question}
        </span>
      </div>
    </button>
    """
  end

  # The voice picker popup, shared by the answer byline and the composer's
  # default-voice control: Plain first, then the game-specific section, then
  # the remaining built-ins under "Alternatives".
  attr :voices, :list, required: true
  attr :game_name, :string, required: true
  attr :current, :string, required: true
  attr :event, :string, required: true
  attr :msg_id, :any, default: nil
  attr :up, :boolean, default: false

  defp voice_menu(assigns) do
    {game_voices, builtin_voices} =
      Enum.split_with(assigns.voices, &String.starts_with?(&1.id, "g:"))

    {plain_voices, alt_voices} = Enum.split_with(builtin_voices, &(&1.id == "neutral"))

    assigns =
      assign(assigns,
        plain_voices: plain_voices,
        game_voices: game_voices,
        alt_voices: alt_voices
      )

    ~H"""
    <div
      class={["card-menu__pop", @up && "card-menu__pop--up"]}
      style="min-width:230px;max-width:280px;max-height:min(45vh,320px);overflow-y:auto"
    >
      <.voice_menu_item
        :for={v <- @plain_voices}
        voice={v}
        event={@event}
        msg_id={@msg_id}
        selected={@current == v.id}
      />
      <%= if @game_voices != [] do %>
        <div style="font-size:0.55rem;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:var(--accent);padding:0.2rem 0.4rem 0.05rem;border-top:1px solid var(--border);margin-top:0.15rem;padding-top:0.35rem">
          ✦ {@game_name}
        </div>
        <.voice_menu_item
          :for={v <- @game_voices}
          voice={v}
          event={@event}
          msg_id={@msg_id}
          selected={@current == v.id}
        />
      <% end %>
      <div style="font-size:0.55rem;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:var(--text-muted);padding:0.2rem 0.4rem 0.05rem;border-top:1px solid var(--border);margin-top:0.15rem;padding-top:0.35rem">
        Alternatives
      </div>
      <.voice_menu_item
        :for={v <- @alt_voices}
        voice={v}
        event={@event}
        msg_id={@msg_id}
        selected={@current == v.id}
      />
    </div>
    """
  end

  # One row in the voice picker menu: fixed emoji gutter + left-aligned label
  # with an optional muted description line, always full menu width.
  attr :voice, :map, required: true
  attr :event, :string, required: true
  attr :msg_id, :any, default: nil
  attr :selected, :boolean, required: true

  defp voice_menu_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-id={@msg_id}
      phx-value-voice={@voice.id}
      class="card-menu__item"
      style={"display:flex;width:100%;justify-content:flex-start;align-items:flex-start;white-space:normal;#{if @selected, do: "background:var(--accent);color:var(--accent-text,#fff)"}"}
    >
      <span aria-hidden="true" style="flex:none;width:1.3rem;text-align:center">{@voice.emoji}</span>
      <span style="flex:1;min-width:0;display:flex;flex-direction:column;align-items:flex-start;text-align:left">
        <span>{@voice.label}</span>
        <span
          :if={@voice[:description]}
          style="font-size:0.6rem;font-weight:400;opacity:0.7;line-height:1.3"
        >{@voice.description}</span>
      </span>
    </button>
    """
  end

  # ── Verdict stamp ──
  # Maps the persisted verdict to {emoji, label, color, bg}. `nil` = no stamp.
  # Theme-aware verdict stamps: text uses the theme's semantic color, background
  # a faint tint of it over the surface — so they adapt to light/dark and to the
  # per-game palette instead of fixed pastels that clash on dark themes.
  defp verdict_stamp("legal"), do: {"✅", "LEGAL MOVE", "var(--green)", stamp_bg("--green")}
  defp verdict_stamp("illegal"), do: {"❌", "NOT ALLOWED", "var(--red)", stamp_bg("--red")}
  defp verdict_stamp("silent"), do: {"🤔", "RULES SILENT", "var(--yellow)", stamp_bg("--yellow")}
  defp verdict_stamp("info"), do: {"📖", "IN THE RULES", "var(--blue)", stamp_bg("--blue")}
  defp verdict_stamp(_), do: nil

  defp stamp_bg(var), do: "color-mix(in srgb, var(#{var}) 16%, var(--bg-surface))"

  # ── Answer confidence meter ──
  # Pure heuristic from existing signals — no stored confidence column.
  # Returns {label, level, color, help_text, next_step}. `level` is 1..conf_max()
  # and drives a segmented meter (a coarse tier reads more honestly than a fake
  # exact percentage). next_step is nil at the top level (Community-verified);
  # otherwise it tells the user how to reach the next, more-trusted level.
  @conf_max 6
  defp conf_max, do: @conf_max

  defp answer_confidence(msg) do
    cond do
      # Admin-verified is the absolute ceiling: an admin explicitly signed off on
      # this exact answer. Checked first so it outranks community votes.
      msg[:verified] ->
        {"Admin-verified", 6, "var(--green)",
         "An admin reviewed and confirmed this answer against the rulebook — the highest level of trust.",
         nil}

      # Community-verified (trusted pool hit). A provisional pool hit is *not*
      # checked here — it carries the source row's citation, so it should read at
      # its citation strength, the same as when freshly asked, rather than
      # dropping a level just because it was served from the pool.
      msg[:pool_hit] && !msg[:pool_provisional] ->
        {"Community-verified", 5, "var(--green)",
         "Other players upvoted this same answer, so it's been confirmed by the community.",
         "Admin-verified — when an admin reviews and confirms this answer."}

      present?(msg[:cited_passage]) && msg[:cited_page] ->
        {"Cited from rulebook", 4, "var(--green)",
         "The answer quotes exact rulebook text and points to the page it came from — strong support straight from the rules.",
         "Community-verified — when other players ask the same thing and upvote this answer."}

      present?(msg[:cited_passage]) ->
        {"Cited passage, page unconfirmed", 3, "var(--blue)",
         "The answer quotes rulebook text, but the exact page number couldn't be confirmed.",
         "Cited from rulebook — regenerate to try to pin the exact page."}

      msg[:pool_hit] && msg[:pool_provisional] ->
        {"Unverified — single source", 2, "var(--yellow)",
         "An earlier answer to a similar question with no rulebook citation. It hasn't been confirmed by other players yet.",
         "Community-verified — once other players upvote this answer too."}

      true ->
        {"No direct citation", 1, "var(--yellow)",
         "No exact rulebook passage matched. This is the model's best read of the rules — double-check anything important.",
         "Cited from rulebook — regenerate to pull a direct rulebook citation."}
    end
  end

  # Short tier word for a confidence level, shown beside the segmented meter.
  defp conf_word(1), do: "Low"
  defp conf_word(2), do: "Fair"
  defp conf_word(3), do: "Good"
  defp conf_word(4), do: "Strong"
  defp conf_word(5), do: "Verified"
  defp conf_word(6), do: "Official"

  # ── Difficulty badge ──
  # Max weight across the base game and currently-selected expansions —
  # expansions only add complexity, never reduce it.
  defp difficulty_weight(game, expansions_and_selection)

  # `included` is the `@included_expansions` assign: a map of `expansion_id =>
  # true` (toggling an expansion off deletes its key rather than setting
  # false), so every present key is selected — no need to filter by value.
  defp difficulty_weight(game, {expansions, included}) when is_map(included) do
    selected_ids = Map.keys(included)

    selected_weights =
      expansions
      |> Enum.filter(&(&1.id in selected_ids))
      |> Enum.map(& &1.weight)
      |> Enum.reject(&is_nil/1)

    [game.weight | selected_weights]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      weights -> Enum.max(weights)
    end
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  # ── BGG stat pills (overview / start screen) ──
  defp bgg_stats(game) do
    [
      player_stat(game),
      game.playing_time && {"⏱️", "#{game.playing_time} min"},
      game.year_published && {"📅", "#{game.year_published}"},
      game.bgg_rank && {"🏆", "BGG ##{game.bgg_rank}"}
    ]
    |> Enum.filter(& &1)
  end

  defp player_stat(%{min_players: nil, max_players: nil}), do: nil
  defp player_stat(%{min_players: n, max_players: n}), do: {"👥", "#{n} players"}
  defp player_stat(%{min_players: nil, max_players: n}), do: {"👥", "#{n} players"}
  defp player_stat(%{min_players: n, max_players: nil}), do: {"👥", "#{n}+ players"}
  defp player_stat(%{min_players: min, max_players: max}), do: {"👥", "#{min}–#{max} players"}

  # ── Random rule card ──
  # Load cached LLM facts. Generation is not automatic — it runs when an admin
  # finalizes the source. Subscribe so a finalize while this page is open streams
  # the result in live; never enqueue here.
  defp load_did_you_know(game, sources, connected?) do
    case RuleMaven.Settings.get("did_you_know_#{game.id}") do
      nil ->
        if sources != [] and connected? do
          Phoenix.PubSub.subscribe(
            RuleMaven.PubSub,
            RuleMaven.Workers.DidYouKnowWorker.topic(game.id)
          )
        end

        []

      json ->
        Jason.decode!(json)
    end
  end

  # Load the cached setup checklist (already subscribed to Setup.topic in mount).
  # Generation is not automatic — it runs at finalize. Returns {status, checklist}.
  defp load_setup(game, _sources) do
    {RuleMaven.Setup.status(game.id), RuleMaven.Setup.stored_checklist(game.id)}
  end

  # Deltas for the currently-included expansions that have one stored, in
  # expansion-name order (the `expansions` assign is already name-sorted).
  defp load_expansion_deltas(expansions, included) do
    expansions
    |> Enum.filter(&Map.get(included, &1.id))
    |> Enum.flat_map(fn exp ->
      case RuleMaven.ExpansionDelta.stored(exp.id) do
        nil -> []
        delta -> [{exp, delta}]
      end
    end)
  end

  # Push the current checked-item set to the browser so the ChecklistStore hook
  # can persist it in localStorage (keyed per game).
  defp push_checklist_save(socket, done) do
    push_event(socket, "save_checklist", %{
      game_id: socket.assigns.game.id,
      keys: MapSet.to_list(done)
    })
  end

  # Wrap a random generated fact in the shape the card template expects, or nil
  # when none have been generated yet (the card is simply hidden). Generated
  # facts have no page citation.
  defp fact_card([]), do: nil
  defp fact_card(facts), do: %{content: Enum.random(facts), page_number: nil}

  # Deterministic fact pick for the initial render: the static and connected
  # mounts must agree, else the card flickers or shifts layout on connect.
  # Seeded by the per-load dyk_seed (stable across both renders, re-rolled on
  # refresh).
  defp dyk_card_for([], _seed), do: nil

  defp dyk_card_for(facts, seed) do
    idx = rem(:erlang.phash2(seed), length(facts))
    %{content: Enum.at(facts, idx), page_number: nil}
  end

  # Strip [Page N] markers and collapse whitespace for friendly card display.
  defp clean_rule_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\[Page\s*\d+\]/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # A message's citation list, preferring the new multi-citation field and
  # falling back to the legacy scalar fields for rows saved before the
  # `citations` column existed (or the mock/legacy-wrap path in AskWorker).
  # The raw list is then grouped (same page + source merge into one card,
  # quotes joined with an ellipsis) and sorted by page ascending.
  defp citation_list(msg) do
    case msg[:citations] do
      list when is_list(list) and list != [] ->
        group_and_sort_citations(list)

      _ ->
        if msg[:cited_passage] do
          [
            %{
              "quote" => msg.cited_passage,
              "page" => msg[:cited_page],
              "source" => msg[:cited_source]
            }
          ]
        else
          []
        end
    end
  end

  # Merges citations that share the same {page, source} into one card (quotes
  # joined with " … ", in original relative order), then sorts cards by page
  # ascending. A citation with no page sorts after every page-bearing card —
  # true textual contiguity between two quotes can't be determined from what's
  # persisted (only the quote/page/source triple is stored, not the source
  # rulebook text), so every merged (2+ quote) card always gets the ellipsis.
  defp group_and_sort_citations(citations) do
    citations
    |> Enum.group_by(&{&1["page"], &1["source"]})
    |> Enum.map(fn {{page, source}, group} ->
      joined_quote = group |> Enum.map(& &1["quote"]) |> Enum.join(" … ")
      %{"page" => page, "source" => source, "quote" => joined_quote}
    end)
    |> Enum.sort_by(fn %{"page" => page} -> {page == nil, page} end)
  end

  # ── Markdown rendering ──

  defp render_markdown(text) do
    case MDEx.to_html(text) do
      {:ok, html} ->
        html
        |> then(&"<div class=\"md-answer\" style=\"line-height:1.4;margin:0\">#{&1}</div>")
        |> Phoenix.HTML.raw()

      {:error, _} ->
        text
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.raw()
    end
  end

  # One aggregate toast per batch of newly settled correct votes. Only on the
  # connected mount so it fires once, not on the dead render too.
  defp maybe_curator_notice(socket) do
    user = socket.assigns.current_user

    with true <- connected?(socket),
         n when n > 0 <- RuleMaven.Games.Curation.unseen_correct_count(user) do
      RuleMaven.Games.Curation.mark_notices_seen(user)

      msg =
        if n == 1 do
          "1 of your votes was confirmed — +1 curator point. See your Standing page for details."
        else
          "#{n} of your votes were confirmed — +#{n} curator points. See your Standing page for details."
        end

      Phoenix.LiveView.put_flash(socket, :info, msg)
    else
      _ -> socket
    end
  end
end
