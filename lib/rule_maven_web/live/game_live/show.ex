defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMavenWeb.ReportModal
  alias RuleMavenWeb.GameLive.{SubBar, ToolHost, ToolPanel}

  # Events delegated to the shared ToolHost; the house-rule subset also
  # recomputes this page's answer overlay after the shared handler runs.
  @tool_events RuleMavenWeb.GameLive.ToolHost.events()
  @hr_overlay_events ~w(add_house_rule edit_house_rule delete_house_rule
                        toggle_house_rule_visibility toggle_house_rule_enabled
                        recheck_house_rule block_house_rule)
  alias Oban

  import RuleMavenWeb.GameLive.ToolHelpers

  @max_concurrent 5

  # A restyle finishes with a `{:voice_ready, ...}` broadcast, but Phoenix.PubSub
  # only reaches subscribers on the node that ran the job. Any second BEAM
  # sharing the Oban queue (a stray `mix phx.server`, a worktree run, a remote
  # console) can dequeue the VoiceWorker job and broadcast where nobody is
  # listening — the loader then spins forever even though `answer_voices` holds
  # the finished restyle. So every enqueue also arms a poll against the DB, the
  # one piece of state both nodes share. It stops on the first hit, and gives up
  # (plain answer, no loader) once a restyle has had well past its worst-case
  # latency to land.
  @voice_poll_ms 2_500
  @voice_poll_max 48

  @impl true
  def mount(_params, session, socket) do
    socket = maybe_curator_notice(socket)

    {:ok,
     assign(socket,
       is_admin: RuleMaven.Users.can?(socket.assigns.current_user, :admin),
       my_groups: [],
       active_group_id: nil,
       # "Keep this in the crew" composer checkbox — never_pool for this ask.
       # Only rendered/read while a group is active; reset on group switch.
       keep_in_crew: false,
       group_feed: [],
       # Per-page-load seed (set by the :put_dyk_seed plug). Identical across the
       # dead render and the connected mount, so the "Did you know?" card picks
       # the same fact on both; re-rolls on a real refresh.
       dyk_seed: session["dyk_seed"] || :rand.uniform(1_000_000_000),
       game: nil,
       question: "",
       conversation: [],
       # thread_id => the raw text the asker just typed on an ask that got
       # deduped/redirected to that thread. Used only to disclose "You asked: …"
       # against their latest wording (the provisional row is deleted on dedup).
       reask_typed: %{},
       threads: [],
       active_thread_id: nil,
       pending_count: 0,
       pending: %{},
       max_concurrent: @max_concurrent,
       source_count: 0,
       retry_cooldowns: %{},
       confirm_delete_id: nil,
       # Persona picker modal: nil when closed, else %{target: :default | {:answer, id}}.
       # popular/recent are computed once when the modal opens.
       persona_modal: nil,
       persona_popular: MapSet.new(),
       persona_recent: [],
       suggestions: [],
       suggestions_open: true,
       suggestions_modal: false,
       settle_modal: false,
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
       tour_autostart: false,
       coarse_pointer: coarse_pointer?(socket)
     )}
  end

  # The per-browser default voice, read from the localStorage connect param so
  # it's already set at the connected mount. Left unvalidated here (the game
  # isn't loaded yet); apply_default_voice/2 coerces an unknown/stale voice to
  # neutral once handle_params has the game. Falls back to neutral on the dead
  # render and whenever nothing is saved.
  # Phones get one bottom sheet at a time instead of a window stack. The dead
  # render has no connect params; assume a stack and let the connected mount
  # correct it (a sheet can't be dragged anyway, so nothing is lost).
  # Mount-only: connect params are unreadable from handle_params, so the result
  # is stashed in the :coarse_pointer assign for later reads.
  defp coarse_pointer?(socket) do
    connected?(socket) and get_connect_params(socket)["coarse_pointer"] == true
  end

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

    # Landing on the page shows the start screen (overview: suggested
    # questions, setup checklist) — no active thread — unless ?t=THREAD_ID
    # explicitly targets a thread. A thread already selected in this session
    # (socket assign) is kept across patches. ?start=1 forces the overview.
    active_thread_id =
      cond do
        params["start"] ->
          nil

        t = params["t"] ->
          case RuleMaven.Hashid.decode(t) do
            {:ok, tid} ->
              if Enum.any?(threads, &(&1.id == tid)), do: tid, else: nil

            :error ->
              nil
          end

        id = socket.assigns.active_thread_id ->
          if Enum.any?(threads, &(&1.id == id)), do: id, else: nil

        true ->
          nil
      end

    conversation =
      build_conversation_for_thread(grouped, active_thread_id, socket.assigns.current_user.id)

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

    # ?t navigation that lands on a different thread than the one on screen
    # (browser back/forward, a pasted link). Event handlers that assign the new
    # thread before patching push scroll_top themselves, so this never doubles.
    prev_thread_id = socket.assigns[:active_thread_id]

    socket =
      assign(socket,
        game: game,
        voices: RuleMaven.Voices.for_game(game),
        page_title: game.name,
        conversation: conversation,
        threads: threads,
        active_thread_id: active_thread_id,
        sources: sources,
        has_cheatsheet: ToolHost.has_cheatsheet?(sources),
        expansions: expansions,
        included_expansions: included_expansions,
        expansion_deltas: ToolHost.load_expansion_deltas(expansions, included_expansions),
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
        asks_disabled: not RuleMaven.Flags.enabled?(:asks, socket.assigns.current_user),
        question_categories: question_categories
      )

    # Tool data + window state load once per mount (seeded_before gates first
    # vs later handle_params) — a thread patch must not reset open windows.
    socket = if seeded_before, do: socket, else: ToolHost.mount_tools(socket, game)

    # Active-group selector (sticky per {user, game}): loaded once per mount,
    # same seeded_before gate as the tool windows above — a thread patch must
    # not re-derive it. Stickiness only honors a stashed group the user is
    # still a member of (they may have been removed since the last visit).
    socket =
      if seeded_before do
        socket
      else
        my_groups = RuleMaven.Groups.list_for_user(socket.assigns.current_user)

        sticky =
          RuleMaven.TableSession.get(socket.assigns.current_user.id, game.id)[:active_group_id]

        active_group_id =
          if sticky && Enum.any?(my_groups, &(&1.id == sticky)), do: sticky, else: nil

        socket
        |> assign(my_groups: my_groups, active_group_id: active_group_id)
        |> assign_group_feed()
      end

    # Restyle the just-loaded thread's answers to the current voice (switching
    # threads, ?t navigation, reload). No-op on first mount where the default is
    # still neutral — the VoiceDefault hook then fires default_voice_restore.
    socket = socket |> apply_default_voice(socket.assigns.default_voice) |> load_hr_overlay()

    socket =
      if not is_nil(prev_thread_id) and prev_thread_id != active_thread_id,
        do: push_event(socket, "scroll_top", %{}),
        else: socket

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
        question: shown_question(g.primary, current_user_id),
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

  # True when the normalized/displayed question meaningfully differs from the raw
  # text the user typed. Ignores capitalization and whitespace so trivial cleanups
  # don't trigger the "You asked:" disclosure.
  defp normalization_changed?(original, displayed)
       when is_binary(original) and is_binary(displayed),
       do: canon_compare(original) != canon_compare(displayed)

  defp normalization_changed?(_original, _displayed), do: false

  # Remember the raw text the asker just typed against the thread their ask was
  # deduped/redirected to, so the disclosure can show their latest wording even
  # though the provisional row carrying it was deleted. Ignores blank text.
  defp stash_reask(map, thread_id, asked_as)
       when is_binary(asked_as) and asked_as != "",
       do: Map.put(map, thread_id, asked_as)

  defp stash_reask(map, _thread_id, _asked_as), do: map

  defp canon_compare(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # The active group, re-authorized against the DB on every use.
  #
  # Membership was previously checked only at mount and at `set_active_group`,
  # so a member removed from the crew mid-session kept a live socket that both
  # READ the crew's feed (each :ask_complete re-queried it) and WROTE into it
  # (their next ask was still stamped with the group_id). Re-deriving authority
  # per use costs one indexed lookup and makes removal take effect immediately.
  defp live_group_id(socket) do
    gid = socket.assigns[:active_group_id]
    uid = socket.assigns.current_user && socket.assigns.current_user.id

    if gid && RuleMaven.Groups.member_of_group_id?(uid, gid), do: gid, else: nil
  end

  defp question_group_opts(socket) do
    if socket.assigns.is_admin do
      [limit: nil]
    else
      [user_id: socket.assigns.current_user.id]
    end
  end

  # The verbatim text as typed, but only for the asker's own row. `nil` for any
  # foreign row (including admin views), so the "↳ You asked:" disclosure —
  # which renders `original_question` verbatim — can never expose someone
  # else's raw wording, group or otherwise.
  defp own_raw_question(%{user_id: uid, question: question}, uid) when not is_nil(uid),
    do: question

  defp own_raw_question(_q, _current_user_id), do: nil

  # `also_asked` is the asker's VERBATIM prose — the answer prompt asks the model
  # for "the exact text of the additional questions" when one message carries more
  # than one. It is a second copy of the raw wording, sitting outside the
  # question/cleaned_question/canonical_question triad that `display_question/1`
  # and `listed_question/1` mediate, and the conversation rendered it to every
  # reader of the row as clickable "Related questions" chips.
  #
  # That made it an end-run around every gate: a crew question could clear the
  # publish screen on its scrubbed primary text and still show a stranger the raw
  # secondary one. It is not a group-only hole either — an ordinary promoted
  # community row displays a mediated `canonical_question` in its bubble while
  # these chips showed the asker's unedited words right underneath.
  #
  # Same rule as the raw question, then: only ever hand it to the person who
  # typed it.
  defp own_also_asked(%{user_id: uid, also_asked: also}, uid) when not is_nil(uid), do: also || []

  defp own_also_asked(_q, _current_user_id), do: []

  # `followups` are model-authored, not copied verbatim — so unlike `also_asked`
  # they are not automatically the asker's prose, and withholding them from every
  # non-author would gut the "Related questions" feature on ordinary community
  # rows. But they ARE generated from the crew's raw question in the same response,
  # they echo its proper nouns, and nothing scrubs them.
  #
  # So the test is CLEARANCE, not authorship: the author always sees their own, and
  # anyone else sees them only once the row has been cleared for listing. For a crew
  # row that means the publish screen passed — and `screen_text/2` now submits the
  # followups along with the question, so what cleared is what shows.
  defp shown_followups(%{user_id: uid, followups: f}, uid) when not is_nil(uid), do: f || []

  defp shown_followups(%{browsable: true, followups: f}, _uid), do: f || []
  defp shown_followups(%{visibility: "community", followups: f}, _uid), do: f || []
  defp shown_followups(_q, _current_user_id), do: []

  # The model's full JSON envelope — verdict, citation quotes, followups, AND a
  # verbatim copy of `also_asked`. It renders in an admin-only <details> block, and
  # an admin's thread list carries every user's rows, so gating the `also_asked`
  # FIELD while leaving this beside it just moved the leak one key over. Admins keep
  # the debug view for public rows; a crew row's envelope is withheld like its text.
  defp own_raw_response(%{user_id: uid, raw_response: raw}, uid) when not is_nil(uid), do: raw

  defp own_raw_response(q, _current_user_id) do
    if QuestionLog.crew_origin?(q), do: nil, else: q.raw_response
  end

  # The question text to DISPLAY for a row in the thread list / conversation.
  #
  # Your own row shows your own wording (display_question's raw fallback is your
  # own prose). Anyone else's goes through `listed_question/1`, which never falls
  # back to the raw column for a crew row. This matters because an admin's
  # `question_group_opts/1` drops the user scope entirely — their sidebar carries
  # every user's rows, including crew rows, and for a `skip_normalize` crew row
  # (cleaned_question: nil) a bare display_question/1 renders the crew member's
  # verbatim prose.
  defp shown_question(%{user_id: uid} = q, uid) when not is_nil(uid),
    do: QuestionLog.display_question(q)

  defp shown_question(q, _current_user_id), do: QuestionLog.listed_question(q)

  # Build flat conversation for a single thread (root + regen history).
  defp build_conversation_for_thread(grouped, thread_id, current_user_id) do
    case Enum.find(grouped, &(&1.primary.id == thread_id)) do
      nil -> []
      g -> build_conversation([g], current_user_id)
    end
  end

  defp build_conversation(grouped, current_user_id) do
    grouped
    |> Enum.flat_map(fn g ->
      user_msg = %{
        id: g.primary.id,
        role: :user,
        content: shown_question(g.primary, current_user_id),
        cleaned_question: g.primary.cleaned_question,
        # Carried so build_recent_pairs/1 can tell whether this turn was actually
        # scrubbed before quoting it into another ask's prompt.
        question_normalized: g.primary.question_normalized,
        # The RAW question is the asker's verbatim prose. Only ever hand it to
        # the person who typed it: an admin, or a row pulled in by an upvote,
        # must never see another user's original wording (that is the whole
        # point of the scrubbed `cleaned_question`).
        original_question: own_raw_question(g.primary, current_user_id),
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
        raw_response: own_raw_response(g.primary, current_user_id),
        followups: shown_followups(g.primary, current_user_id),
        also_asked: own_also_asked(g.primary, current_user_id),
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
            raw_response: own_raw_response(h, current_user_id),
            followups: shown_followups(h, current_user_id),
            also_asked: own_also_asked(h, current_user_id),
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

  defp vote_error_message(:settled),
    do: "This answer has been settled — its votes are final."

  defp vote_error_message(_), do: "Couldn't record your vote."

  # Source rows behind pool hits in the current thread — so their vote
  # counts/state load alongside the community list.
  # Every question_log id this page rendered a vote control for: the community
  # list, the open thread's own answers, and the pool sources behind pool hits
  # (the Helpful thumb on a pool hit targets the source row). Anything outside
  # this set is a forged id.
  defp rendered_vote_ids(socket) do
    conversation = socket.assigns[:conversation] || []

    Enum.map(socket.assigns[:community_questions] || [], & &1.id) ++
      conversation_source_ids(conversation) ++ conversation_answer_ids(conversation)
  end

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
  # Best-effort persona-selection stat (popularity + recently-used). Never
  # affects the reply.
  defp record_persona_pick(socket, voice) do
    uid = socket.assigns.current_user && socket.assigns.current_user.id
    RuleMaven.Voices.record_event(uid, socket.assigns.game.id, voice)
  end

  defp clear_failed_for_voice(failed, voice) do
    Enum.reduce(failed, failed, fn
      {_id, ^voice} = pair, acc -> MapSet.delete(acc, pair)
      _pair, acc -> acc
    end)
  end

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

          # A restyle that already failed must not be re-enqueued here.
          # apply_default_voice runs on EVERY :ask_complete for the game —
          # including other users' asks — so without this a single doomed
          # {id, voice} pair re-paid an LLM restyle every time anyone on the
          # game finished a question. Re-picking the voice clears the flag.
          MapSet.member?(acc.assigns.voice_failed, {id, voice}) ->
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

            Process.send_after(self(), {:voice_poll, id, voice, 1}, @voice_poll_ms)

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

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_refused", _params, socket) do
    {:noreply, assign(socket, show_refused: !socket.assigns.show_refused)}
  end

  # Sticky active-group selector in the sub-bar: "" (or a missing/garbage/
  # not-a-member token) always resolves to nil ("Just me") — `phx-value-*` is
  # client-controlled, so the group must be re-verified server-side via
  # `member?/2` rather than trusted from the token alone.
  def handle_event("set_active_group", %{"group" => token}, socket) do
    user = socket.assigns.current_user

    group_id =
      case token do
        "" ->
          nil

        t ->
          case RuleMaven.Groups.get_group_by_token(t) do
            %{} = group -> if RuleMaven.Groups.member?(user, group), do: group.id, else: nil
            nil -> nil
          end
      end

    game = socket.assigns.game
    snap = RuleMaven.TableSession.get(user.id, game.id)
    RuleMaven.TableSession.put(user.id, game.id, Map.put(snap, :active_group_id, group_id))

    {:noreply,
     socket
     |> assign(active_group_id: group_id, keep_in_crew: false)
     |> assign_group_feed()}
  end

  # Per-ask "Keep this in the crew" checkbox: a one-off never_pool for the
  # NEXT ask, independent of the group's own contribute_to_community setting.
  def handle_event("toggle_keep_in_crew", _params, socket) do
    {:noreply, assign(socket, :keep_in_crew, not socket.assigns.keep_in_crew)}
  end

  # Table tools (window state, quiz, turn wizard, checklist, house rules) are
  # shared with the Community page via ToolHost — one delegating clause here.
  # House-rule changes additionally refresh the Show-only answer overlay.
  def handle_event(event, params, socket) when event in @tool_events do
    {:noreply, socket} = ToolHost.handle_tool_event(event, params, socket)
    socket = if event in @hr_overlay_events, do: load_hr_overlay(socket), else: socket
    {:noreply, socket}
  end

  # "How does my rule change this answer?" — cache hit renders instantly and
  # free; a miss checks quota and enqueues the durable delta worker, showing a
  # spinner until {:house_rule_delta, ...} arrives over PubSub.
  def handle_event("house_rule_delta", %{"id" => id}, socket) do
    with %{} = hr <- ToolHost.get_house_rule(id),
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
      record_persona_pick(socket, voice)

      {:noreply,
       socket
       |> assign(voice_sel: %{}, persona_modal: nil)
       # An explicit pick is the retry gesture for a failed restyle —
       # apply_default_voice skips failed pairs, so clear them here.
       |> assign(voice_failed: clear_failed_for_voice(socket.assigns.voice_failed, voice))
       |> apply_default_voice(voice)
       |> push_event("save_default_voice", %{voice: voice})}
    end
  end

  # Persona picker modal open/close. popular + recent are computed once on open
  # (not per render). target routes the eventual pick to set_default_voice
  # (composer) or set_voice (a specific answer).
  def handle_event("open_persona_modal", params, socket) do
    target =
      case params do
        %{"target" => "answer", "msg-id" => id} -> {:answer, String.to_integer(id)}
        _ -> :default
      end

    game = socket.assigns.game
    uid = socket.assigns.current_user && socket.assigns.current_user.id

    {:noreply,
     assign(socket,
       persona_modal: %{target: target},
       persona_popular: RuleMaven.Voices.popular_voice_ids(game.id),
       persona_recent: RuleMaven.Voices.recent_voice_ids(uid, game.id)
     )}
  end

  def handle_event("close_persona_modal", _params, socket) do
    {:noreply, assign(socket, persona_modal: nil)}
  end

  # Choose a default voice, auto-applied to every answer. Persist it per-browser
  # (the VoiceDefault hook writes localStorage) and apply it to the open thread.
  def handle_event("set_default_voice", %{"voice" => voice}, socket) do
    if RuleMaven.Voices.valid?(voice, socket.assigns.game) do
      record_persona_pick(socket, voice)

      {:noreply,
       socket
       |> assign(persona_modal: nil)
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

    # Scope to the rows this page actually rendered a vote control for (the same
    # guard Community.handle_event("vote", ...) uses), not merely to this game:
    # `set_community_vote/4` only checks that the row is votable, and ids reach
    # the client as raw phx-values, so a game-wide check would let a forged id
    # vote on a row the viewer was never shown.
    if id in rendered_vote_ids(socket) do
      do_community_vote(socket, id, uid, value, new_upvote?)
    else
      {:noreply, socket}
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
  # `handle_params/3` validates `?t=`, but that only runs when the CLIENT sends the
  # patch back — a hand-rolled socket client just doesn't. So this event has to
  # validate on its own: it sets `active_thread_id`, which is the row id that
  # `house_rule_delta` and `load_hr_overlay/1` then feed to the LLM and render.
  # Without this check, any logged-in user could point either of them at any row
  # in any game — including a crew row whose raw question the delta prompt reads.
  def handle_event("switch_thread", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, _} ->
        if Enum.any?(socket.assigns.threads, &(&1.id == id)) do
          {:noreply,
           socket
           |> assign(active_thread_id: id, sidebar_open: false)
           |> push_event("scroll_top", %{})
           |> push_patch(to: ~p"/games/#{socket.assigns.game}?t=#{RuleMaven.Hashid.encode(id)}")}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("quick_ask", %{"question" => question}, socket) do
    handle_event("ask", %{"question" => question}, socket)
  end

  @max_question_length 600
  @min_question_length 3

  def handle_event("ask", %{"question" => question}, socket) do
    # Strip --- sequences so user input can't inject parser delimiters into LLM output
    question = question |> String.replace("---", "") |> String.trim()

    # Never trust the client's visibility: "community" rows are pool-eligible
    # and pool_tier treats them as trusted, so a tampered payload would inject
    # an unvetted answer into every other user's cache. New asks are always
    # private; only curation/promotion can make a row community.
    visibility = "private"

    cond do
      Games.taken_down?(socket.assigns.game) ->
        {:noreply,
         put_flash(socket, :error, "This game has been removed and can't be asked about.")}

      not socket.assigns.game.playable and not socket.assigns.is_admin ->
        {:noreply, put_flash(socket, :error, "This game isn't ready yet — check back soon.")}

      not RuleMaven.Flags.enabled?(:asks, socket.assigns.current_user) ->
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
               |> assign(
                 question: "",
                 active_thread_id: cross_thread_dup.id,
                 sidebar_open: false,
                 reask_typed:
                   stash_reask(socket.assigns.reask_typed, cross_thread_dup.id, question)
               )
               |> put_flash(:info, "You already asked this — here's your answer.")
               |> push_event("scroll_top", %{})
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

                group_id = live_group_id(socket)

                case Games.log_question_with_rate_limit(socket.assigns.current_user, %{
                       game_id: game.id,
                       question: question,
                       answer: "Thinking...",
                       user_id: socket.assigns.current_user.id,
                       visibility: visibility,
                       group_id: group_id,
                       browsable: is_nil(group_id),
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
                      group_id: group_id,
                      never_pool: socket.assigns[:keep_in_crew] || false,
                      voice: socket.assigns.default_voice
                    }
                    |> RuleMaven.Workers.AskWorker.new()
                    |> Oban.insert()

                    {:noreply,
                     socket
                     |> assign(
                       question: "",
                       keep_in_crew: false,
                       active_thread_id: question_log.id,
                       rule_card: ToolHost.fact_card(socket.assigns.dyk_facts),
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
      conversation =
        build_conversation_for_thread(
          grouped,
          socket.assigns.active_thread_id,
          socket.assigns.current_user.id
        )

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

  def handle_event("open_settle", _params, socket),
    do: {:noreply, assign(socket, settle_modal: true)}

  def handle_event("close_settle", _params, socket),
    do: {:noreply, assign(socket, settle_modal: false)}

  # Compose the two opposing readings into a normal ask — the answer prompt's
  # ARGUMENT SETTLING rule opens the reply with a ⚖️ verdict line.
  def handle_event("submit_settle", %{"a" => a, "b" => b}, socket) do
    a = String.trim(a)
    b = String.trim(b)

    if a == "" or b == "" do
      {:noreply, put_flash(socket, :error, "Enter both sides of the argument.")}
    else
      q =
        "Settle an argument — Player A says: \"#{a}\" Player B says: \"#{b}\" " <>
          "Which is right under the rules?"

      socket = assign(socket, settle_modal: false)
      handle_event("ask", %{"question" => q}, socket)
    end
  end

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

    case favorite_scoped(socket, id) do
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

    verify_result =
      if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
        case find_question_log(game, id) do
          nil -> :ok
          q -> Games.toggle_verified(q)
        end
      else
        :ok
      end

    socket =
      case verify_result do
        {:error, :not_publishable} ->
          put_flash(
            socket,
            :error,
            "This question came from a private crew and hasn't cleared the privacy check, so it can't be published to the community."
          )

        _ ->
          socket
      end

    grouped = Games.grouped_questions(game, question_group_opts(socket))

    conversation =
      build_conversation_for_thread(
        grouped,
        socket.assigns.active_thread_id,
        socket.assigns.current_user.id
      )

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

    # Scoped: the trace carries prompts and per-call cost. Admin alone isn't the
    # gate — the row must belong to the game whose page this is.
    if socket.assigns.is_admin and Games.get_game_question(socket.assigns.game, id) do
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
  def handle_event("ask_exactly", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user = socket.assigns.current_user

    # "Ask exactly this" — the single escape hatch when the served answer didn't
    # fit what the asker meant, whether because the normalizer rewrote their
    # question OR the pool matcher served a similar-but-different neighbor. Re-ask
    # their LITERAL wording with no normalization (skip_normalize) and no cache
    # (skip_pool), so neither a rewrite nor a wrong pool match can recur. Bumps
    # the mismatch counter (lands on the pool source for a pool copy, else the
    # row itself) and drops an audit entry so admins can review bad rewrites.
    # Own answered rows only; the button is gated the same way in the template,
    # but LiveView events are forgeable.
    q = find_question_log(socket.assigns.game, id)

    if user && q && q.user_id == user.id && q.answer != "Thinking..." do
      # Audit policy, applied consistently across every Audit.log call on a
      # question: the LABEL is scrubbed (`listed_question/1`) because it renders
      # in the audit LIST — a scanning surface — while the METADATA keeps the raw
      # text, because that is the forensic record and admins already read raw
      # wording in the moderation views. Scrubbing it here would also make this
      # entry a tautology: it exists so an admin can compare what the user TYPED
      # against the rewrite, and "original" would just repeat "cleaned".
      RuleMaven.Audit.log(user, "question.ask_verbatim",
        target_type: "question",
        target_id: q.id,
        target_label: QuestionLog.listed_question(q),
        metadata: %{"original" => q.question, "cleaned" => q.cleaned_question}
      )

      Games.record_pool_mismatch(q, user.id)

      socket
      |> put_flash(:info, "Asking your exact wording — fetching a fresh answer.")
      |> then(&resubmit_question(id, &1, skip_pool: true, verbatim: true))
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

  defp do_community_vote(socket, id, uid, value, new_upvote?) do
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

  defp refresh_house_rules(socket) do
    socket |> ToolHost.refresh_house_rules() |> load_hr_overlay()
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

        conversation =
          build_conversation_for_thread(
            grouped,
            socket.assigns.active_thread_id,
            socket.assigns.current_user.id
          )

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
    # Verbatim ("Ask exactly this"): re-ask the raw text the asker typed instead
    # of the cleaned bubble content, and skip normalization so it isn't rewritten
    # again. The raw text comes from the DB row below, not the conversation.
    verbatim = Keyword.get(opts, :verbatim, false)
    cooldowns = socket.assigns.retry_cooldowns
    now = System.system_time(:second)

    existing = find_question_log(socket.assigns.game, id)

    # Sourced from the ROW, not from the rendered bubble. The bubble's `content`
    # is `shown_question/2`, which withholds a foreign crew row's text — and an
    # admin's conversation carries every user's rows. Re-asking the bubble text
    # would therefore delete a crew member's question and pay an LLM call to
    # answer the literal string "(question withheld)".
    question = if existing, do: QuestionLog.display_question(existing), else: ""

    # LiveView events are forgeable, and `grouped_questions/1` puts every
    # community row into every viewer's conversation — so without this a user
    # could regenerate, and below DELETE, someone else's promoted answer.
    # Own rows only; admins keep the unrestricted re-ask.
    foreign_row? =
      (existing && existing.user_id != socket.assigns.current_user.id) and
        not socket.assigns.is_admin

    cond do
      not RuleMaven.Flags.enabled?(:asks, socket.assigns.current_user) ->
        {:noreply, put_flash(socket, :error, RuleMaven.Settings.asks_disabled_message())}

      question == "" ->
        {:noreply, socket}

      foreign_row? ->
        {:noreply, socket}

      true ->
        %{game: game, included_expansions: included} = socket.assigns
        expansion_ids = Map.keys(included)

        old_q = existing

        # Verbatim re-ask uses the raw text as stored, rather than the
        # canonical/cleaned text `display_question/1` prefers above.
        question = if verbatim && old_q, do: old_q.question, else: question

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
        #
        # A promoted (community) row gets the same protection even with zero
        # votes yet: it is shared content the moment it is promoted, and its
        # author regenerating must not delete it out from under other viewers.
        # A crew row that isn't the actor's own is protected too. Regenerating
        # DELETES the source row when it isn't protected, and admins pass
        # `foreign_row?` by design — so one click on an admin's view of a crew
        # member's question removed that Q&A from the crew's feed permanently, for
        # everyone, with no trace and no way back. The crew's shared history is not
        # the admin's to rewrite; the regen goes to a fresh private copy instead.
        #
        # `crew_origin?/1`, not `group_id` — the nilify trap. Keyed on the column,
        # this guard was blind to precisely the rows that need it most: a DELETED
        # crew's rows, whose text was never screened and which no longer carry the
        # marker saying so.
        protect_existing? =
          old_q &&
            (Games.has_votes?(old_q.id) or old_q.visibility == "community" or
               (QuestionLog.crew_origin?(old_q) and
                  old_q.user_id != socket.assigns.current_user.id))

        # Drop cached persona restyles only when the row's answer is actually
        # going away. A PROTECTED row keeps its answer (the regen goes to a
        # fresh private copy), so clearing its restyles just made every other
        # persona viewer re-pay an LLM call for identical text.
        if old_q && not protect_existing? do
          RuleMaven.Voices.clear_for_question(id)
          Games.delete_question(old_q)
        end

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

        # A re-ask inherits the SOURCE row's boundary — it must not be able to
        # take its text from one context and its publishability from another.
        #
        # `question` above came from `old_q` (verbatim re-ask reuses the raw
        # column outright), so reading `group_id` from the socket's current
        # selector was a laundering path: ask in the crew, flip the selector back
        # to "Just me", hit "Ask exactly this" on your own answer, and the crew's
        # unscreened wording lands in a group_id: nil, browsable: true row that
        # the public Unverified tab lists verbatim. Two clicks, no forgery.
        source_group_id = old_q && old_q.group_id
        uid = socket.assigns.current_user.id

        # A row that CAME from a crew falls back to no crew at all — never to the
        # actor's own. `foreign_row?` lets admins through by design, and an admin's
        # thread list carries every user's rows, so regenerating a crew member's
        # question re-homed it into whatever crew the ADMIN happened to have
        # selected: the victim crew's wording, rendered in a different crew's feed,
        # readable by people who were never in the room. Falling through to
        # `live_group_id/1` is only correct when the source row had no crew of its
        # own to inherit.
        #
        # The crew-provenance test is `crew_origin?/1`, not `source_group_id`: for a
        # DELETED crew the id is already nil, so the group_id-keyed version fell
        # straight through to the actor's own crew — laundering the retraction
        # `delete_group/2` had just performed.
        crew_row? = old_q && QuestionLog.crew_origin?(old_q)

        group_id =
          cond do
            source_group_id && RuleMaven.Groups.member_of_group_id?(uid, source_group_id) ->
              source_group_id

            crew_row? ->
              nil

            true ->
              live_group_id(socket)
          end

        # Even where the group_id can't be carried over (the user has since left
        # the crew), text derived from a crew row stays unpublished.
        #
        # The inherited axis is crew PROVENANCE (`old_q.group_id`), not crew
        # CLEARANCE (`old_q.browsable`). A cleared crew row is browsable because
        # the screen passed its SCRUBBED text — while a verbatim re-ask copies the
        # RAW column, which is precisely what the scrub removed. Inheriting
        # `browsable` would therefore wave through exactly the rows whose raw text
        # a screen has already judged unsafe to publish.
        # `crew_origin?/1` rather than `old_q.group_id` — same nilify trap. A
        # deleted crew's row has a nil group_id and unscreened text, and this test
        # used to wave it straight through as `browsable: true`.
        browsable =
          is_nil(group_id) and
            (is_nil(old_q) or (not crew_row? and old_q.browsable))

        case Games.log_question_with_rate_limit(socket.assigns.current_user, %{
               game_id: game.id,
               question: question,
               answer: "Thinking...",
               user_id: socket.assigns.current_user.id,
               visibility: visibility,
               group_id: group_id,
               browsable: browsable,
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
              group_id: group_id,
              skip_pool: skip_pool,
              skip_normalize: verbatim,
              # Either a private one-off (regenerate/report redo of an already-voted
              # answer) or the composer's "keep this in the crew" toggle keeps the
              # answer out of the shared pool. `protect_existing?` is `old_q && (...)`,
              # which can be `nil` (not a strict boolean) when there's no prior row —
              # `||` tolerates that where `or` would raise.
              # A re-ask of a WITHDRAWN row must not put its answer back into the
              # commons through the side door: the crew pulled it, and copying the
              # text into a fresh row does not un-pull it.
              never_pool:
                ((protect_existing? || false) or (socket.assigns[:keep_in_crew] || false) or
                   (old_q && not is_nil(old_q.retracted_at))) || false,
              # Without the voice a persona user's regenerate skips the
              # single-call persona path and pays a separate restyle call.
              voice: socket.assigns.default_voice
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
               # Counted from the freshly-built list, as everywhere else.
               # Arithmetic on the old counter drifted: `was_pending` reads the
               # DB row ("Thinking..."), but :check_stale marks a stuck thread
               # non-pending in ASSIGNS only — retrying it skipped the
               # increment while inserting a pending thread, so @max_concurrent
               # then admitted an extra in-flight ask.
               pending_count: Enum.count(threads, & &1.pending),
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
  # Favoriting is harmless in itself, but the id is off the wire: keep it inside
  # the game the user is looking at rather than any pooled row anywhere.
  defp favorite_scoped(socket, id) do
    if Games.get_game_question(socket.assigns.game, id) do
      Games.toggle_answer_favorite(socket.assigns.current_user.id, id)
    else
      {:error, :not_found}
    end
  end

  defp find_question_log(game, id) do
    import Ecto.Query
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id and q.game_id == ^game.id)
  end

  defp get_question_log_by_id(id) do
    import Ecto.Query
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  # The active group's question feed (Task 11): newest-first, attributed,
  # scoped to this game + this group by `Games.recent_questions/3`. Reloaded
  # (never patched in place) on group switch and on a matching `:ask_complete`
  # broadcast — a full re-query is authorized here and sidesteps duplicate-row
  # bugs a targeted prepend would risk.
  defp assign_group_feed(socket) do
    case live_group_id(socket) do
      nil ->
        assign(socket, :group_feed, [])

      gid ->
        assign(
          socket,
          :group_feed,
          Games.recent_questions(socket.assigns.game, 20, group_id: gid)
        )
    end
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
        {:ask_redirect, %{question_log_id: prov_id, source_question_log_id: source_id} = payload},
        socket
      ) do
    if Enum.any?(socket.assigns.threads, &(&1.id == prov_id)) do
      # Drop the provisional thread entirely — its row was deleted by the
      # worker. Leaving it would count as pending forever, eventually hitting
      # @max_concurrent and blocking all asks until reload.
      threads = Enum.reject(socket.assigns.threads, &(&1.id == prov_id))

      {:noreply,
       socket
       |> assign(
         threads: threads,
         pending_count: Enum.count(threads, & &1.pending),
         active_thread_id: source_id,
         reask_typed: stash_reask(socket.assigns.reask_typed, source_id, payload[:asked_as]),
         ask_partial: Map.delete(socket.assigns.ask_partial, prov_id),
         ask_stage: Map.delete(socket.assigns.ask_stage, prov_id)
       )
       |> put_flash(:info, "You already asked this — here's your answer.")
       |> push_event("scroll_top", %{})
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
                    question: shown_question(ql, socket.assigns.current_user.id),
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
              |> Map.put(:content, shown_question(ql, socket.assigns.current_user.id))
              |> Map.put(:cleaned_question, ql.cleaned_question)
              |> Map.put(:question_normalized, ql.question_normalized)
              |> Map.put(
                :original_question,
                own_raw_question(ql, socket.assigns.current_user.id)
              )

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
                |> Map.put(:followups, shown_followups(ql, socket.assigns.current_user.id))
                # Re-gated on every live update, not just at build_conversation
                # time — otherwise the broadcast quietly puts the raw text back.
                |> Map.put(:also_asked, own_also_asked(ql, socket.assigns.current_user.id))
                |> Map.put(:refused, ql.refused)
                |> Map.put(:raw_response, own_raw_response(ql, socket.assigns.current_user.id))
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

      # Task 11: this broadcast is game-wide, so every viewer's session gets
      # it — not just the asker's. When the answered question was asked under
      # the SAME group this viewer currently has active, refresh the group
      # feed panel so it live-appends. Folded into this single existing
      # clause (not a second `handle_info({:ask_complete, ...})` clause)
      # deliberately: Elixir matches clauses top-down, and a second clause
      # guarded on `group_id` would have to sit either before this one (where
      # it would swallow every group ask before the asker's own conversation
      # update above ever ran) or after it (dead code, since this clause
      # matches every `:ask_complete` payload shape already). Reusing the
      # already-computed `question_log_id`/`data` here keeps both behaviors —
      # the asker's own conversation update and the group feed refresh —
      # running for the exact same message.
      socket =
        case Map.get(data, :group_id) do
          gid when not is_nil(gid) ->
            if gid == live_group_id(socket), do: assign_group_feed(socket), else: socket

          _ ->
            socket
        end

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
      # The broadcast is game-wide, so `answer_ready?` is false in every OTHER
      # viewer's session too: without the ownership check, anyone's completed
      # ask scrolled every other reader on the game to the bottom.
      own_thread? = Enum.any?(socket.assigns.threads, &(&1.id == question_log_id))

      {:noreply,
       if(answer_ready? or not own_thread?,
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
         ToolHost.load_expansion_deltas(
           socket.assigns.expansions,
           socket.assigns.included_expansions
         )
     )}
  end

  # Streamed answer text for a still-pending ask. Only track partials for
  # rows this LiveView is actually showing as pending — every viewer of the
  # game topic receives the broadcast, but only the asker has the pending row.
  # Real pipeline progress from LLM.ask — only track questions this session is
  # actually waiting on (the broadcast goes to every viewer of the game topic).
  # Early normalized-question push: settle the asker's question bubble to its
  # final form (cleaned text + "You asked" disclosure) before any answer text
  # streams underneath, so the answer never reflows the page as it loads. Only
  # touches the active thread's still-pending user turn.
  def handle_info(
        {:ask_normalized, %{question_log_id: ql_id, cleaned: cleaned}},
        socket
      ) do
    active? = socket.assigns.active_thread_id == ql_id

    still_pending? =
      Enum.any?(
        socket.assigns.conversation,
        &(&1[:id] == ql_id && &1[:role] == :assistant && &1[:pending])
      )

    if active? and still_pending? do
      # `active?` is not ownership: an admin's thread list carries every user's
      # rows, so the raw wording is re-read from the row and handed back only to
      # its author (own_raw_question/2 returns nil for anyone else).
      original =
        case get_question_log_by_id(ql_id) do
          nil -> nil
          ql -> own_raw_question(ql, socket.assigns.current_user.id)
        end

      conversation =
        Enum.map(socket.assigns.conversation, fn
          %{id: ^ql_id, role: :user} = msg ->
            msg
            |> Map.put(:content, cleaned)
            |> Map.put(:cleaned_question, cleaned)
            |> Map.put(:original_question, original)

          msg ->
            msg
        end)

      {:noreply, assign(socket, conversation: conversation)}
    else
      {:noreply, socket}
    end
  end

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

  # Backstop for a `{:voice_ready, ...}` that never arrives — see @voice_poll_ms.
  # Only polls while the restyle is still pending here; a broadcast that beat the
  # timer has already cleared it, so this is a no-op in the common case.
  def handle_info({:voice_poll, ql_id, voice, attempt}, socket) do
    cond do
      not MapSet.member?(socket.assigns.voice_pending, {ql_id, voice}) ->
        {:noreply, socket}

      content = RuleMaven.Voices.get(ql_id, voice) ->
        {:noreply,
         assign(socket,
           voice_cache: Map.put(socket.assigns.voice_cache, {ql_id, voice}, content),
           voice_pending: MapSet.delete(socket.assigns.voice_pending, {ql_id, voice}),
           voice_failed: MapSet.delete(socket.assigns.voice_failed, {ql_id, voice})
         )}

      attempt < @voice_poll_max ->
        Process.send_after(self(), {:voice_poll, ql_id, voice, attempt + 1}, @voice_poll_ms)
        {:noreply, socket}

      true ->
        # Out of patience: the job died, was discarded, or is wedged. Drop the
        # loader and show the plain answer. No flash — unlike a reported
        # `:voice_failed` this is our own timeout, and the answer is intact.
        {:noreply,
         assign(socket,
           voice_pending: MapSet.delete(socket.assigns.voice_pending, {ql_id, voice}),
           voice_failed: MapSet.put(socket.assigns.voice_failed, {ql_id, voice})
         )}
    end
  end

  def handle_info({:voice_ready, ql_id, voice, content}, socket) do
    cache = Map.put(socket.assigns.voice_cache, {ql_id, voice}, content)
    pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})
    failed = MapSet.delete(socket.assigns.voice_failed, {ql_id, voice})
    {:noreply, assign(socket, voice_cache: cache, voice_pending: pending, voice_failed: failed)}
  end

  def handle_info({:voice_failed, ql_id, voice}, socket) do
    # VoiceWorker broadcasts to the game-wide topic, so this fires in every
    # open session on the game. Only the session that actually requested this
    # {id, voice} restyle should react — otherwise a stranger's failed persona
    # pops an error toast over someone reading a different thread.
    if MapSet.member?(socket.assigns.voice_pending, {ql_id, voice}) do
      pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})
      failed = MapSet.put(socket.assigns.voice_failed, {ql_id, voice})

      {:noreply,
       socket
       |> assign(voice_pending: pending, voice_failed: failed)
       |> put_flash(:error, "Couldn't apply that persona — showing the plain answer.")}
    else
      {:noreply, socket}
    end
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
    {:noreply, assign(socket, dyk_facts: facts, rule_card: ToolHost.fact_card(facts))}
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
      <SubBar.game_bar
        class="chat-header"
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        current_user={@current_user}
        has_cheatsheet={@has_cheatsheet}
        current={:show}
        expansions={@expansions}
        included_expansions={@included_expansions}
        house_rule_count={length(@house_rules)}
        my_groups={@my_groups}
        active_group_id={@active_group_id}
      >
        <%!-- Sidebar toggle: kept first so it is the leftmost control on
              whichever row this group wraps onto on narrow screens. The
              Rulebooks / Community / Cheat Sheet pills now live in the shared
              bar, so every game screen paints them identically. --%>
        <button
          type="button"
          phx-click="toggle_sidebar"
          class="sidebar-toggle btn-icon btn-sm"
        >☰</button>
      </SubBar.game_bar>

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
          style="flex-shrink:0;width:min(16rem,85vw);overflow-y:auto;border-right:1px solid var(--border);background:color-mix(in srgb,var(--bg-surface) 50%,transparent);backdrop-filter:blur(7px);-webkit-backdrop-filter:blur(7px);padding:0.5rem 0;font-size:0.9rem;display:flex;flex-direction:column;position:relative;z-index:1"
        >
          <%!-- Title + search ride along at the top of the scrolling list.
                The drawer itself is the scroll container, so a sticky child
                pins against it. --%>
          <div class="sidebar-head">
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
                class="sidebar-close-btn btn-icon"
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
          </div>

          <!-- Community questions -->
          <%= if @community_questions != [] do %>
            <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
              Community
            </div>
            <%= for q <- @community_questions do %>
              <%!-- listed_question, not the raw `question` column: searching a
                    field the viewer is never shown turns this box into an oracle
                    that reconstructs a crew member's wording a letter at a time. --%>
              <%= if @search_query == "" || String.contains?(String.downcase(QuestionLog.listed_question(q)), String.downcase(@search_query)) do %>
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
                    {QuestionLog.listed_question(q)}
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
               Enum.all?(@community_questions, fn q -> @search_query == "" || not String.contains?(String.downcase(QuestionLog.listed_question(q)), String.downcase(@search_query)) end) do %>
            <div style="padding:0.5rem 0.75rem;color:var(--text-muted);font-size:0.72rem;font-style:italic">
              No matching questions
            </div>
          <% end %>
          <%!-- Empty state. The glyph floats and the copy rises in, matching the
                staggered `sidebar-item-in` the populated list uses, so the panel
                never reads as a dead box. Deliberately not a skeleton shimmer:
                nothing is loading, and shimmer would promise rows that aren't
                coming. --%>
          <div :if={@threads == [] && @community_questions == []} class="sidebar-empty">
            <div class="sidebar-empty__glyph" aria-hidden="true">💬</div>
            <p class="sidebar-empty__title">No questions yet</p>
            <p class="sidebar-empty__hint">Ask one below — it'll show up here.</p>
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
                class="btn btn-primary btn-sm"
              >
                Add rulebook text or PDF
              </.link>
            </div>
          <% end %>

          <!-- Persistent Did-you-know: once a conversation starts the full
               empty-state card is gone, so keep a slim sticky version pinned
               above the answers (a fast reply otherwise steals the fact). -->
          <%= if @rule_card && @conversation != [] do %>
            <div style="position:sticky;top:-1rem;z-index:5;margin:-1rem -1rem 1rem;padding:0.4rem 2.9rem 0.4rem 0.75rem;background:var(--bg-surface);border-bottom:1px solid var(--border);box-shadow:0 3px 8px rgba(0,0,0,0.07);font-size:0.72rem;line-height:1.35;color:var(--text)">
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

              <%!-- One-click opt-in to this game's own colors. Only shown when
                   a palette exists; the hook self-hides it once a game variant
                   is already active. --%>
              <button
                :if={RuleMavenWeb.GameLive.GameTheme.has_palette?(@game)}
                type="button"
                id="game-theme-hint"
                phx-hook="GameThemeHint"
                data-tour="game-theme-hint"
                style="margin:1.1rem auto 0;display:inline-flex;align-items:center;justify-content:center;gap:0.4rem;max-width:100%;white-space:normal;text-align:center;line-height:1.35;overflow-wrap:anywhere;background:var(--bg-surface);border:1px solid var(--border);border-radius:999px;padding:0.4rem 0.9rem;font-size:0.75rem;font-weight:700;color:var(--accent-ink,var(--accent));cursor:pointer;box-shadow:0 1px 3px rgba(0,0,0,0.06)"
              >
                🖌️ Dress this page in {@game.name}'s colors
              </button>

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
                          class="btn-sm"
                          style="display:block;width:100%;text-align:left;margin-bottom:0.2rem;white-space:normal;word-break:break-word;line-height:1.45"
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
                        <button
                          type="button"
                          phx-click={show_voice && "open_persona_modal"}
                          phx-value-target="answer"
                          phx-value-msg-id={msg[:id]}
                          disabled={!show_voice}
                          aria-disabled={!show_voice}
                          style={"font-size:0.65rem;font-weight:600;border-radius:999px;padding:0.12rem 0.5rem;display:inline-flex;align-items:center;gap:0.2rem;cursor:pointer;#{if !show_voice, do: "opacity:0.55;pointer-events:none;"}#{if speaking, do: "border:1px solid color-mix(in srgb,var(--accent) 55%,transparent);background:color-mix(in srgb,var(--accent) 12%,transparent);color:var(--text)", else: "border:1px solid var(--border);background:var(--bg-surface);color:var(--text-muted)"}"}
                          title="Answer persona — your pick applies to every answer and is remembered"
                        >
                          <span
                            :if={String.starts_with?(cur_voice, "g:")}
                            aria-hidden="true"
                            style="color:var(--accent-ink, var(--accent))"
                          >✦</span>
                          <span aria-hidden="true">{cur.emoji}</span>
                          <span>{if speaking,
                            do: "#{cur.label} speaking",
                            else: "#{cur.label} persona"}</span>
                          <span style="opacity:0.6">▾</span>
                        </button>
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
                    <%!-- Keying the text node by voice makes LiveView replace it
                          rather than patch it whenever the persona changes, so
                          the .answer-in rise animation replays instead of the
                          restyled text popping in. The streaming branch reuses
                          the same id: an unchanged voice means the node survives
                          the stream → final swap and never re-animates over text
                          the stream already revealed. Role is in the id because a
                          question and its answer share a question_log id. --%>
                    <% answer_dom_id = "ans-#{msg.role}-#{msg[:id]}-#{v_sel}" %>
                    <%= cond do %>
                      <% thinking? && stream_text -> %>
                        <div class="answer-in" id={answer_dom_id}>
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
                        <div class="answer-in">
                          <%!-- Voice in the id so switching persona mid-wait replaces
                                the ignored element — remounting the hook with the new
                                persona's phrases and label. The id is shared across
                                the thinking → voicing stages so the loader (and its
                                phrase cycle) persists seamlessly between them. --%>
                          <%!-- No persona name/emoji row here: the persona button
                                directly above already shows "<name> speaking", so
                                repeating "<name> ANSWERING…" in the loader was
                                redundant. --%>
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
                        <div class="answer-in" id={answer_dom_id}>
                          {render_markdown(v_content || msg.content)}
                        </div>
                        <%!-- Disclose that we rewrote the asker's raw question into
                              a normalized form. The raw text is shown ONLY to the
                              person who typed it: `build_conversation/2` sets
                              `original_question` to nil on any row the viewer does
                              not own (a foreign row can reach this chat via an
                              upvote on a pooled answer, and admins see every row),
                              and `@reask_typed` only ever holds text this session
                              typed. --%>
                        <% asked_as = Map.get(@reask_typed, msg[:id]) || msg[:original_question] %>
                        <%= if msg.role == :user &&
                               normalization_changed?(asked_as, msg.content) do %>
                          <div class="ask-orig">
                            <span class="ask-orig__label">↳ You asked:</span>
                            <span class="conf-help">
                              <button
                                type="button"
                                class="conf-help__btn"
                                aria-label="Why the wording changed"
                              >?</button>
                              <span class="conf-help__pop" role="tooltip">
                                We rewrote your question into a standard form before
                                searching the rulebook. It helps match the right rules
                                and reuse trusted answers to similar questions. Your
                                original wording is always kept.
                              </span>
                            </span>
                            <span class="ask-orig__text">"{asked_as}"</span>
                          </div>
                        <% end %>
                        <%!-- "Ask exactly this" — escape hatch below the original
                              question when the served answer may not fit what the
                              asker meant: the wording was rewritten OR the pool
                              matched a similar-but-different neighbor. Re-asks the
                              literal words with no cache + no rewrite. Gated on the
                              paired answer being ready; hidden once the wording
                              matches (incl. the verbatim re-ask's own row, so it
                              can't loop). Own rows only — non-admins are scoped to
                              their own threads and the server re-checks ownership. --%>
                        <% ans_msg =
                          msg.role == :user &&
                            Enum.find(@conversation, &(&1[:id] == msg.id && &1.role == :assistant)) %>
                        <% answer_ready? =
                          ans_msg && !ans_msg[:pending] && !ans_msg[:refused] &&
                            ans_msg.content != "Thinking..." && is_binary(ans_msg.content) &&
                            not String.starts_with?(ans_msg.content, "⚠️") %>
                        <%= if answer_ready? &&
                               (ans_msg[:pool_hit] ||
                                  normalization_changed?(asked_as, msg.content)) do %>
                          <button
                            type="button"
                            phx-click="ask_exactly"
                            phx-value-id={msg.id}
                            disabled={@pending_count >= @max_concurrent}
                            data-confirm="Re-ask using your exact original wording, without rewriting or reusing a cached answer? We'll fetch a fresh answer for exactly what you asked."
                            class="ask-redo"
                            title="Answer my literal wording — fresh, no rewrite"
                          >🎯 Ask exactly this</button>
                        <% end %>
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
                            <span style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                              {c["source"] || "Rulebook"}
                            </span>
                            <span class="cite-page">p.{c["page"]}</span>
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
                            class="btn-sm"
                            style="display:block;width:100%;box-sizing:border-box;text-align:left;line-height:1.35;white-space:normal;overflow-wrap:anywhere"
                          >{q}</button>
                        <% end %>
                        <%= if has_also do %>
                          <button
                            :for={q <- msg[:also_asked]}
                            type="button"
                            phx-click="quick_ask"
                            phx-value-question={q}
                            disabled={@pending_count >= @max_concurrent}
                            class="btn-sm"
                            style="display:block;width:100%;box-sizing:border-box;text-align:left;line-height:1.35;white-space:normal;overflow-wrap:anywhere"
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
                          class="btn-xs"
                        >Setup</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="How do turns work?"
                          disabled={@pending_count >= @max_concurrent}
                          class="btn-xs"
                        >Turn order</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="How does scoring work?"
                          disabled={@pending_count >= @max_concurrent}
                          class="btn-xs"
                        >Scoring</button>
                        <button
                          type="button"
                          phx-click="ask_suggestion"
                          phx-value-q="What are the win conditions?"
                          disabled={@pending_count >= @max_concurrent}
                          class="btn-xs"
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
                          class="btn-xs"
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
                            class="btn-xs"
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
                          class="btn-xs"
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
                        <.vote_thumb
                          event="community_vote"
                          id={msg[:id]}
                          voted={cv == "up"}
                          count={Map.get(counts, :up, 0)}
                          title={if cv == "up", do: "Remove vote", else: "Helpful"}
                        />
                        <span
                          :if={MapSet.member?(@asker_confirmed_ids, msg[:id])}
                          style="font-size:0.6rem;color:var(--accent-ink, var(--accent));border:1px solid currentColor;border-radius:0.5rem;padding:0 0.35rem;line-height:1.4;white-space:nowrap"
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
                          <.vote_thumb
                            event="community_vote"
                            id={sid}
                            voted={cv == "up"}
                            count={Map.get(counts, :up, 0)}
                            title={if cv == "up", do: "Remove vote", else: "Helpful"}
                          />
                          <span
                            :if={MapSet.member?(@asker_confirmed_ids, sid)}
                            style="font-size:0.6rem;color:var(--accent-ink, var(--accent));border:1px solid currentColor;border-radius:0.5rem;padding:0 0.35rem;line-height:1.4;white-space:nowrap"
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
                          <.vote_thumb
                            event="community_vote"
                            id={msg[:id]}
                            voted={cv == "up"}
                            count={Map.get(counts, :up, 0)}
                            title={
                              if cv == "up",
                                do: "Remove confirmation",
                                else: "Confirm this answered your question"
                            }
                          />
                        </span>
                      <% end %>
                    <% end %>

                    <%!-- Everything else right-aligns in one group: category pills,
                        then the overflow menu. --%>
                    <span style="display:inline-flex;flex-wrap:wrap;align-items:center;gap:0.5rem;margin-left:auto">
                      <!-- Category pills. Shown under any answered question now
                       that unverified answers are browsable by category on the
                       community Q&A page — each pill deep-links into that page
                       filtered to the category. -->
                      <% msg_cats =
                        if msg.role == :assistant && msg[:id],
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
                            type="button"
                            id={"read-btn-#{idx}"}
                            phx-hook="ReadAloud"
                            data-speak={plain_text}
                            aria-pressed="false"
                            class="card-menu__item"
                            title="Read this answer aloud"
                          >🔊 Read aloud</button>
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

      <%!-- Minimized tools: a distinct in-flow bar directly above the composer
            at every width (the messages area shrinks instead of being
            overlaid). The chat shell already ends above the background-job
            bar, so the pills always clear it. --%>
      <ToolPanel.tool_dock tool_states={@tool_states} flow={true} />

      <!-- Input -->
      <%!-- id keys this node for the patcher: without it, a modal appearing
            as the previous sibling gets morphed INTO this div (ids on the
            modals alone don't help), recreating the input area and replaying
            its qa-rise-in entrance animation. --%>
      <div
        id="chat-input-panel"
        class="chat-input"
        style="flex-shrink:0;padding:0.35rem 1rem 0.5rem 1rem;border-top:1px solid var(--border);background:var(--bg-surface);position:relative;z-index:1"
      >
        <div style="max-width:48rem;margin:0 auto;width:100%">
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
          <% cur_default = Enum.find(@voices, &(&1.id == @default_voice)) || hd(@voices) %>
          <form
            phx-submit="ask"
            class="flex gap-2"
            style="flex-wrap:wrap"
            phx-hook="KeyboardSubmit"
            id="ask-form"
          >
            <%!-- Above-the-box controls: question-idea menu (left) and the
                  default answer voice (right). They are form children with
                  `flex-basis:100%` so they claim their own wrapped row above
                  the ask box; on phones `.composer-controls` drops to
                  `flex-basis:auto` and they ride the ask row itself, saving a
                  whole row of a short viewport. The voice applies to every
                  answer and persists in localStorage via VoiceDefault. --%>
            <%!-- data-tour="voices" sits on the wrapper, not the persona pill:
                  the pill is display:none on phones and a hidden step is
                  skipped, but the wrapper is visible on every viewport. --%>
            <div class="composer-controls" data-tour="voices">
              <details class="card-menu" data-tour="suggestions" style="flex-shrink:0">
                <summary
                  class="composer-controls__ideas"
                  title="Question ideas"
                  style="display:inline-flex;align-items:center;gap:0.3rem;font-size:0.7rem;font-weight:600;color:var(--accent-ink, var(--accent));cursor:pointer;list-style:none"
                >
                  <span aria-hidden="true">💡</span>
                  <span class="pill-label">Ideas</span>
                  <span style="opacity:0.6">▾</span>
                </summary>
                <%!-- Opens upward — the ask box sits at the bottom of the
                      viewport. Items close the menu themselves: they open modals
                      in the same LiveView, so no navigation closes it for us. --%>
                <div class="card-menu__pop card-menu__pop--up">
                  <button
                    :if={@suggestions != []}
                    type="button"
                    phx-click="open_suggestions"
                    onclick="this.closest('details').open = false"
                    class="card-menu__item"
                  >
                    <span aria-hidden="true">💡</span> Suggested questions
                  </button>
                  <button
                    type="button"
                    phx-click="open_settle"
                    onclick="this.closest('details').open = false"
                    disabled={
                      @pending_count >= @max_concurrent || @source_count == 0 ||
                        (not @game.playable and not @is_admin)
                    }
                    class="card-menu__item"
                  >
                    <span aria-hidden="true">⚖️</span> Settle an argument
                  </button>
                  <%!-- The persona pill beside this menu is hidden on phones to
                        keep the ask row short, so mirror it as a menu item. --%>
                  <button
                    type="button"
                    id="persona-default-menu-btn"
                    phx-click="open_persona_modal"
                    phx-value-target="default"
                    onclick="this.closest('details').open = false"
                    class="card-menu__item show-mobile"
                  >
                    <span aria-hidden="true">{cur_default.emoji}</span>
                    Answer persona: {cur_default.label}
                  </button>
                </div>
              </details>
              <div
                data-tour="voices"
                class="composer-controls__voice hide-mobile"
                style="display:flex;align-items:center;gap:0.4rem;margin-left:auto"
              >
                <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">Answer persona</span>
                <button
                  type="button"
                  id="persona-default-btn"
                  phx-click="open_persona_modal"
                  phx-value-target="default"
                  style="font-size:0.68rem;color:var(--text);font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.55rem;background:var(--bg-surface);cursor:pointer;display:inline-flex;align-items:center;gap:0.25rem"
                >
                  <span aria-hidden="true">{cur_default.emoji}</span>
                  <span>{cur_default.label}</span>
                  <span style="opacity:0.6">▾</span>
                </button>
              </div>
            </div>
            <%!-- Per-ask privacy override (Gate 4): only shown with a group active.
                  Checked ⇒ never_pool for this one ask — the answer never joins
                  the community cache and the question is never publish-checked,
                  regardless of the group's own contribute_to_community setting. --%>
            <label
              :if={@active_group_id}
              for="keep-in-crew-toggle"
              class="crew-toggle composer-keep-crew"
            >
              <input
                type="checkbox"
                id="keep-in-crew-toggle"
                phx-click="toggle_keep_in_crew"
                checked={@keep_in_crew}
              />
              <span class="crew-toggle__text">
                <span class="crew-toggle__label">Keep this in the crew</span>
                <span class="crew-toggle__hint">Don't share this answer with the wider community.</span>
              </span>
            </label>
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
          <%!-- AI disclaimer: the core caveat (AI can be wrong) must stay visible
                on every ask — product rule. The one-liner keeps it in sight; the
                grounding/sharing details expand on tap. --%>
          <details style="text-align:center;font-size:0.62rem;line-height:1.3;color:var(--text-muted);margin-top:0.3rem">
            <summary class="ai-note-summary" style="cursor:pointer;list-style:none;display:inline">
              🤖 AI can be wrong — double-check important rulings.
              <span style="text-decoration:underline;opacity:0.8">more</span>
            </summary>
            <div style="margin-top:0.2rem">
              Answers use strict guardrails: grounded in the rulebook, citing their sources. Answered questions may be shared anonymously in the Community Q&A.
            </div>
          </details>
        </div>
      </div>

      <%!-- Modals live AFTER the input panel on purpose: position:fixed makes
            DOM order irrelevant visually, and inserting a modal before
            .chat-input made the patcher reinsert the input panel node, which
            restarts its qa-rise-in entrance animation on every modal open. --%>
      <%!-- Report-reason modal: pick why the answer is being reported. --%>
      <ReportModal.report_modal :if={@report_target} />

      <%!-- Suggested-questions modal. Backdrop closes via phx-click-away on the
            panel; picking a question asks it and closes (ask_suggestion). --%>
      <div
        :if={@suggestions_modal}
        id="suggestions-modal"
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
              class="btn-icon"
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
                      class="btn-sm"
                      style="text-align:left;white-space:normal;word-break:break-word;line-height:1.45"
                    >{q}</button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Argument-settler modal: two opposing readings → one composed ask
            whose answer opens with a ⚖️ verdict line. --%>
      <div
        :if={@settle_modal}
        id="settle-modal"
        style="position:fixed;top:0;left:0;right:0;bottom:var(--jobpanel-h, 0px);z-index:60;background:rgba(0,0,0,0.45);display:flex;align-items:flex-end;justify-content:center;padding:1rem"
      >
        <div
          phx-click-away="close_settle"
          phx-window-keydown="close_settle"
          phx-key="Escape"
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;max-width:32rem;width:100%;box-shadow:0 10px 40px rgba(0,0,0,0.3)"
        >
          <div style="display:flex;align-items:center;justify-content:space-between;padding:0.85rem 1rem;border-bottom:1px solid var(--border)">
            <div style="font-size:0.95rem;font-weight:700;color:var(--text)">
              ⚖️ Settle an argument
            </div>
            <button
              type="button"
              phx-click="close_settle"
              aria-label="Close"
              class="btn-icon"
            >✕</button>
          </div>
          <form
            phx-submit="submit_settle"
            style="padding:0.85rem 1rem;display:flex;flex-direction:column;gap:0.7rem"
          >
            <p style="font-size:0.75rem;color:var(--text-muted);margin:0;line-height:1.45">
              Each side states their reading of the rule — the answer opens with a verdict on who's right, citing the rulebook.
            </p>
            <label style="font-size:0.72rem;font-weight:600;color:var(--text-secondary)">
              Player A says…
              <input
                type="text"
                name="a"
                id="settle-a-input"
                phx-hook="FocusInput"
                maxlength={220}
                placeholder="You draw your new card immediately."
                autocomplete="off"
                style="display:block;width:100%;margin-top:0.25rem;background:var(--bg);color:var(--text);border:1px solid var(--border-strong);border-radius:0.4rem;padding:0.45rem 0.6rem;font-size:0.82rem"
              />
            </label>
            <label style="font-size:0.72rem;font-weight:600;color:var(--text-secondary)">
              Player B says…
              <input
                type="text"
                name="b"
                maxlength={220}
                placeholder="No — you wait until the end of the turn."
                autocomplete="off"
                style="display:block;width:100%;margin-top:0.25rem;background:var(--bg);color:var(--text);border:1px solid var(--border-strong);border-radius:0.4rem;padding:0.45rem 0.6rem;font-size:0.82rem"
              />
            </label>
            <button
              type="submit"
              style="align-self:flex-end;background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.45rem 1.1rem;border-radius:2rem;font-weight:600;font-size:0.82rem;cursor:pointer"
            >
              ⚖️ Settle it
            </button>
          </form>
        </div>
      </div>
    </div>

    <%!-- Outside .chat-layout on purpose: that element is `position:fixed;
          z-index:10`, which makes it a stacking context. A tool window nested
          inside it could never paint above the site header (z:100) no matter how
          high its own z-index went, so a window dragged to the top of the screen
          slid under the header and lost its title bar. The dock is rendered
          in-flow inside the chat column instead (dock: false here). --%>
    <ToolPanel.tool_panel {Map.put(assigns, :dock, false)} />

    <%!-- Persona picker modal (shared by the composer default picker and each
          answer's switcher). Outside .chat-layout for the same stacking-context
          reason as the tool panel: nested inside it, the backdrop's z-index:3000
          still resolved below the site header (z:100), so on phones — where the
          modal sits only 3vh from the top — the header painted over its title
          row. position:fixed alone does not escape a stacking context. --%>
    <.persona_modal
      :if={@persona_modal}
      target={@persona_modal.target}
      voices={@voices}
      game={@game}
      default_voice={@default_voice}
      current={persona_modal_current(@persona_modal.target, @voice_sel, @default_voice)}
      popular={@persona_popular}
      recent={@persona_recent}
    />
    """
  end

  # ── Helpers ──

  # Pair consecutive user→assistant messages, ignore history/refused entries.
  # Returns last 2 valid Q&A pairs for followup context.
  defp build_recent_pairs(msgs) do
    msgs
    |> Enum.zip(Enum.drop(msgs, 1))
    |> Enum.filter(fn {a, b} -> a.role == :user && b.role == :assistant end)
    # A turn whose text was never scrubbed is DROPPED from the context, not
    # substituted. Preferring `cleaned_question` and falling back to `content` was
    # a no-op on exactly the turns that matter: a `skip_normalize` row stores
    # `cleaned_question: nil`, so it fell straight back to `content` — which is
    # `display_question/1` for your own row, i.e. the RAW column. It only ever
    # substituted clean text for rows that were already clean.
    #
    # This matters because the NEXT turn's answer is generated with this text in
    # its prompt, and that next turn pools and publishes on the strength of its
    # OWN clean question. Ask turn 1 verbatim in a crew, then ask an innocuous
    # turn 2 — even with the crew switched off, since the thread's conversation
    # survives in the socket — and turn 1's names ride into the commons inside
    # turn 2's answer, on a row the publish screen never even looks at.
    |> Enum.filter(fn {user, _asst} -> scrubbed_turn?(user) end)
    |> Enum.map(fn {user, asst} -> %{q: recent_q(user), a: asst.content} end)
    |> Enum.take(-2)
  end

  # Only a turn the normalize step actually rewrote may be quoted into another
  # ask's prompt. The optimistic/pending message maps carry no `:question_normalized`
  # key at all, and a map pattern simply fails to match — so they are dropped too,
  # which is right: they have no answer yet and nothing to contribute as context.
  defp scrubbed_turn?(%{question_normalized: true, cleaned_question: cleaned})
       when is_binary(cleaned),
       do: String.trim(cleaned) != ""

  defp scrubbed_turn?(_msg), do: false

  # The SCRUBBED form of the prior turn. `scrubbed_turn?/1` has already guaranteed
  # this row was really normalized, so there is no fallback to `content` (the
  # rendered bubble, which is the raw column for your own row) — that fallback was
  # the bug.
  defp recent_q(%{cleaned_question: cleaned}) when is_binary(cleaned), do: cleaned

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

  # Which voice renders as "selected" in the modal for a given target: the
  # composer picks the default; a per-answer switcher picks that answer's
  # current voice (falling back to the default).
  defp persona_modal_current(:default, _voice_sel, default_voice), do: default_voice

  defp persona_modal_current({:answer, msg_id}, voice_sel, default_voice),
    do: Map.get(voice_sel, msg_id, default_voice)

  # The persona picker modal, shared by the composer's default-voice control and
  # each answer's switcher. Centered + viewport-safe; groups personas Plain /
  # ✦ game / Alternatives, with a recently-used strip, search filter, 🔥 Popular
  # badges, descriptions and a sample line.
  attr :target, :any, required: true
  attr :voices, :list, required: true
  attr :game, :map, required: true
  attr :default_voice, :string, required: true
  attr :current, :string, required: true
  attr :popular, :any, required: true
  attr :recent, :list, required: true

  defp persona_modal(assigns) do
    {game_voices, builtin} = Enum.split_with(assigns.voices, &String.starts_with?(&1.id, "g:"))
    {plain, alt} = Enum.split_with(builtin, &(&1.id == "neutral"))
    by_id = Map.new(assigns.voices, &{&1.id, &1})
    recent = Enum.map(assigns.recent, &Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)

    event =
      case assigns.target do
        :default -> "set_default_voice"
        {:answer, _} -> "set_voice"
      end

    assigns =
      assign(assigns,
        plain: plain,
        game_voices: game_voices,
        alt: alt,
        recent_voices: recent,
        event: event
      )

    ~H"""
    <div
      id="persona-modal"
      class="persona-modal-backdrop"
      phx-click="close_persona_modal"
      phx-window-keydown="close_persona_modal"
      phx-key="Escape"
    >
      <div
        id="persona-modal-panel"
        class="persona-modal"
        phx-click-away="close_persona_modal"
        phx-hook="PersonaFilter"
      >
        <div class="persona-modal__head">
          <span class="persona-modal__title">Answer persona</span>
          <button type="button" class="btn-icon" phx-click="close_persona_modal" aria-label="Close">✕</button>
        </div>
        <p class="persona-modal__blurb">
          Personas change how an answer is written, not what it says. Pick a voice and the same
          rules get explained in its style.
        </p>
        <input
          type="text"
          id="persona-search"
          class="persona-modal__search"
          placeholder="Search personas…"
          data-persona-filter-input
          autocomplete="off"
          phx-update="ignore"
        />
        <div class="persona-modal__scroll">
          <div :if={@recent_voices != []} class="persona-modal__section">Recently used</div>
          <.persona_card
            :for={v <- @recent_voices}
            voice={v}
            event={@event}
            selected={@current == v.id}
            is_default={@default_voice == v.id}
            popular={MapSet.member?(@popular, v.id)}
          />

          <.persona_card
            :for={v <- @plain}
            voice={v}
            event={@event}
            selected={@current == v.id}
            is_default={@default_voice == v.id}
            popular={MapSet.member?(@popular, v.id)}
          />

          <div :if={@game_voices != []} class="persona-modal__section persona-modal__section--game">
            ✦ {@game.name}
          </div>
          <.persona_card
            :for={v <- @game_voices}
            voice={v}
            event={@event}
            selected={@current == v.id}
            is_default={@default_voice == v.id}
            popular={MapSet.member?(@popular, v.id)}
          />

          <div class="persona-modal__section">Alternatives</div>
          <.persona_card
            :for={v <- @alt}
            voice={v}
            event={@event}
            selected={@current == v.id}
            is_default={@default_voice == v.id}
            popular={MapSet.member?(@popular, v.id)}
          />
        </div>
      </div>
    </div>
    """
  end

  # One persona card: emoji + label (with 🔥 Popular / ★ default badges),
  # description, and a muted sample line drawn from the persona's loading phrases.
  attr :voice, :map, required: true
  attr :event, :string, required: true
  attr :selected, :boolean, required: true
  attr :is_default, :boolean, required: true
  attr :popular, :boolean, required: true

  defp persona_card(assigns) do
    # The persona's OWN sample line — not the generic loading pool, so a
    # built-in without its own phrases simply shows no sample.
    sample =
      case assigns.voice[:loading_phrases] do
        [p | _] when is_binary(p) -> p
        _ -> nil
      end

    assigns = assign(assigns, :sample, sample)

    ~H"""
    <button
      type="button"
      class={["persona-card", @selected && "persona-card--selected"]}
      phx-click={@event}
      phx-value-voice={@voice.id}
      data-search={String.downcase("#{@voice.label} #{@voice[:description]}")}
    >
      <span class="persona-card__emoji" aria-hidden="true">{@voice.emoji}</span>
      <span class="persona-card__body">
        <span class="persona-card__title">
          {@voice.label}
          <span :if={@popular} class="persona-card__badge">🔥 Popular</span>
          <span
            :if={@is_default}
            class="persona-card__badge persona-card__badge--star"
            title="Your default"
          >★</span>
        </span>
        <span :if={@voice[:description]} class="persona-card__desc">{@voice.description}</span>
        <span :if={@sample} class="persona-card__sample">“{@sample}”</span>
      </span>
      <span :if={@selected} class="persona-card__check" aria-hidden="true">✓</span>
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
