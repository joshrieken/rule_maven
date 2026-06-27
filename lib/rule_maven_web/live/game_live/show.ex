defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, CheatSheet}
  alias Oban

  @max_concurrent 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       is_admin: RuleMaven.Users.game_master?(socket.assigns.current_user),
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
       sidebar_open: false,
       show_refused: false,
       community_vote_counts: %{},
       community_user_votes: %{},
       included_expansions: %{},
       visibility: "private",
       search_query: "",
       community_questions: [],
       community_count: 0,
       refresh: 0,
       show_onboarding: false,
       stale_timer: nil,
       question_categories: %{},
       # Persona voices: per-answer selected voice, lazily-loaded restyle cache
       # keyed by {question_log_id, voice}, and in-flight restyle requests.
       voice_sel: %{},
       voice_cache: %{},
       voice_pending: MapSet.new(),
       rule_card: nil,
       # LLM-generated "Did you know?" facts (durable, per-game). Empty until the
       # worker fills them; the card falls back to a raw rulebook chunk meanwhile.
       dyk_facts: [],
       # Setup checklist (durable, per-game) + per-session checked items.
       setup_status: nil,
       setup_checklist: nil,
       checklist_done: MapSet.new()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    id = params["id"]
    game = Games.get_game!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.Setup.topic(game.id))
    end

    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    threads = build_thread_summaries(grouped)

    # Prefer URL query param ?t=THREAD_ID, then socket assign, then select first
    active_thread_id =
      cond do
        t = params["t"] ->
          case Integer.parse(t) do
            {tid, ""} when is_integer(tid) ->
              if Enum.any?(threads, &(&1.id == tid)), do: tid, else: select_active_thread(threads)

            _ ->
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
    community = Games.community_questions(game, socket.assigns.current_user.id)
    community_count = RuleMaven.Faq.community_count(game)
    cq_ids = Enum.map(community, & &1.id)

    vote_ids = cq_ids ++ conversation_source_ids(conversation)

    {cv_counts, cv_user} =
      Games.community_vote_maps(vote_ids, socket.assigns.current_user.id)

    all_thread_ids = Enum.map(threads, & &1.id)
    question_categories = Games.categories_for_questions(all_thread_ids ++ cq_ids)

    dyk_facts = load_did_you_know(game, sources, connected?(socket))

    socket =
      assign(socket,
        game: game,
        page_title: game.name,
        conversation: conversation,
        threads: threads,
        active_thread_id: active_thread_id,
        sources: sources,
        expansions: expansions,
        included_expansions: socket.assigns.included_expansions,
        source_count: length(sources),
        question: "",
        pending_count: pending_count,
        pending: %{},
        community_questions: community,
        community_count: community_count,
        community_vote_counts: cv_counts,
        community_user_votes: cv_user,
        question_categories: question_categories,
        show_onboarding: conversation == [] && sources != [] && pending_count == 0,
        dyk_facts: dyk_facts,
        rule_card: fact_card(dyk_facts),
        setup_status: RuleMaven.Setup.status(game.id),
        setup_checklist: RuleMaven.Setup.stored_checklist(game.id)
      )

    suggestions =
      case RuleMaven.Settings.get("suggestions_#{game.id}") do
        nil ->
          if sources != [] do
            # Durable generation via Oban; result arrives over PubSub.
            if connected?(socket) do
              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.SuggestionsWorker.topic(game.id)
              )
            end

            RuleMaven.Workers.SuggestionsWorker.enqueue(game.id)
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
  defp build_thread_summaries(grouped) do
    recent = DateTime.utc_now() |> DateTime.add(-120, :second)

    grouped
    |> Enum.map(fn g ->
      pending? =
        g.primary.answer == "Thinking..." &&
          not is_nil(g.primary.inserted_at) &&
          DateTime.compare(g.primary.inserted_at, recent) == :gt

      %{
        id: g.primary.id,
        question: g.primary.question,
        answer: g.primary.answer,
        pending: pending?,
        refused: g.primary.refused,
        favorited: g.primary.favorited,
        inserted_at: g.primary.inserted_at
      }
    end)
    |> Enum.sort_by(fn t -> {if(t.favorited, do: 0, else: 1), t.inserted_at} end, fn
      {fa, ta}, {fb, tb} -> fa < fb || (fa == fb && DateTime.compare(ta, tb) == :gt)
    end)
  end

  # Build flat conversation for a single thread (root + history + followups).
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
        content: g.primary.question,
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
        verdict: g.primary.verdict,
        llm_provider: g.primary.llm_provider,
        llm_model: g.primary.llm_model,
        pinned: g.primary.pinned,
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
            verdict: h.verdict,
            llm_provider: h.llm_provider,
            llm_model: h.llm_model,
            pinned: h.pinned,
            refused: h.refused,
            raw_response: h.raw_response,
            followups: h.followups,
            also_asked: h.also_asked,
            timestamp: h.inserted_at,
            history: true
          }
        end)

      followup_msgs =
        Enum.flat_map(g.followups, fn f ->
          f_user = %{
            id: f.id,
            role: :user,
            content: f.question,
            cleaned_question: f.cleaned_question,
            refused: f.refused,
            followup: true,
            timestamp: f.inserted_at
          }

          f_asst = %{
            id: f.id,
            role: :assistant,
            content: f.answer,
            cited_passage: f.cited_passage,
            cited_page: f.cited_page,
            verdict: f.verdict,
            llm_provider: f.llm_provider,
            llm_model: f.llm_model,
            pinned: f.pinned,
            refused: f.refused,
            raw_response: f.raw_response,
            followups: f.followups,
            also_asked: f.also_asked,
            timestamp: f.inserted_at
          }

          [f_user, f_asst]
        end)

      [user_msg, assistant_msg | history_msgs] ++ followup_msgs
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> mark_pending_thinking()
  end

  # Source rows behind provisional pool hits in the current thread — so their
  # vote counts/state load alongside the community list.
  defp conversation_source_ids(conversation) do
    conversation
    |> Enum.filter(& &1[:pool_source_id])
    |> Enum.map(& &1[:pool_source_id])
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
  def handle_event("toggle_expansion", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    included = socket.assigns.included_expansions

    included =
      if included[id] do
        Map.delete(included, id)
      else
        Map.put(included, id, true)
      end

    {:noreply, assign(socket, included_expansions: included)}
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

  def handle_event("generate_setup", _params, socket) do
    RuleMaven.Setup.generate_async(socket.assigns.game)
    {:noreply, assign(socket, setup_status: "generating")}
  end

  def handle_event("toggle_step", %{"key" => key}, socket) do
    done = socket.assigns.checklist_done

    done =
      if MapSet.member?(done, key),
        do: MapSet.delete(done, key),
        else: MapSet.put(done, key)

    {:noreply, assign(socket, checklist_done: done)}
  end

  def handle_event("reset_checklist", _params, socket) do
    {:noreply, assign(socket, checklist_done: MapSet.new())}
  end

  # Switch one answer to a persona voice. Neutral and already-cached voices swap
  # instantly (no cost); an uncached voice enqueues a durable restyle job and
  # shows a spinner until {:voice_ready, ...} arrives over PubSub.
  def handle_event("set_voice", %{"id" => id_str, "voice" => voice}, socket) do
    {id, _} = Integer.parse(id_str)

    if not RuleMaven.Voices.valid?(voice) do
      {:noreply, socket}
    else
      sel = Map.put(socket.assigns.voice_sel, id, voice)

      cond do
        voice == "neutral" ->
          {:noreply, assign(socket, voice_sel: sel)}

        Map.has_key?(socket.assigns.voice_cache, {id, voice}) ->
          {:noreply, assign(socket, voice_sel: sel)}

        cached = RuleMaven.Voices.get(id, voice) ->
          # In DB but not in this session's cache — load it, still free.
          cache = Map.put(socket.assigns.voice_cache, {id, voice}, cached)
          {:noreply, assign(socket, voice_sel: sel, voice_cache: cache)}

        true ->
          %{question_log_id: id, voice: voice, game_id: socket.assigns.game.id}
          |> RuleMaven.Workers.VoiceWorker.new()
          |> Oban.insert()

          pending = MapSet.put(socket.assigns.voice_pending, {id, voice})
          {:noreply, assign(socket, voice_sel: sel, voice_pending: pending)}
      end
    end
  end

  def handle_event("community_vote", %{"id" => id_str, "vote" => value}, socket) do
    {id, _} = Integer.parse(id_str)
    uid = socket.assigns.current_user.id
    Games.set_community_vote(id, uid, value)

    vote_ids =
      Enum.map(socket.assigns.community_questions, & &1.id) ++
        conversation_source_ids(socket.assigns.conversation)

    {cv_counts, cv_user} = Games.community_vote_maps(vote_ids, uid)
    {:noreply, assign(socket, community_vote_counts: cv_counts, community_user_votes: cv_user)}
  end

  @impl true
  def handle_event("switch_thread", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    {:noreply,
     socket
     |> assign(active_thread_id: id, sidebar_open: false)
     |> push_patch(to: ~p"/games/#{socket.assigns.game.id}?t=#{id}")}
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
            if socket.assigns.pending_count >= @max_concurrent do
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Maximum #{@max_concurrent} concurrent questions. Please wait for one to finish."
               )}
            else
              case Games.check_rate_limit(socket.assigns.current_user) do
                :ok ->
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

                  case Games.log_question(%{
                         game_id: game.id,
                         question: question,
                         answer: "Thinking...",
                         user_id: socket.assigns.current_user.id,
                         visibility: visibility
                       }) do
                    {:ok, question_log} ->
                      %{
                        game_id: game.id,
                        question_log_id: question_log.id,
                        question: question,
                        expansion_ids: expansion_ids,
                        recent_context: recent,
                        user_id: socket.assigns.current_user.id
                      }
                      |> RuleMaven.Workers.AskWorker.new()
                      |> Oban.insert()

                      {:noreply,
                       socket
                       |> assign(
                         question: "",
                         active_thread_id: question_log.id,
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
                       |> push_patch(to: ~p"/games/#{game.id}?t=#{question_log.id}")
                       |> push_event("scroll_bottom", %{})}

                    {:error, _} ->
                      {:noreply, put_flash(socket, :error, "Failed to save question")}
                  end

                {:error, reason} ->
                  {:noreply, put_flash(socket, :error, reason)}
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

    case find_question_log(game, id) do
      nil -> :ok
      q -> Games.delete_question(q)
    end

    # Rebuild threads and conversation from DB
    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    threads = build_thread_summaries(grouped)

    deleted_was_active = socket.assigns.active_thread_id == id
    pending_count = Enum.count(threads, & &1.pending)

    if deleted_was_active do
      {:noreply,
       assign(socket,
         threads: threads,
         conversation: [],
         active_thread_id: nil,
         pending_count: pending_count,
         show_onboarding: socket.assigns.source_count > 0,
         confirm_delete_id: nil
       )
       |> push_patch(to: ~p"/games/#{game.id}")}
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
  def handle_event("dismiss_onboarding", _params, socket) do
    {:noreply, assign(socket, show_onboarding: false)}
  end

  @impl true
  def handle_event("cancel_delete_question", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  @impl true
  def handle_event("toggle_visibility", _params, socket) do
    next = if socket.assigns.visibility == "community", do: "private", else: "community"
    {:noreply, assign(socket, visibility: next)}
  end

  @impl true
  def handle_event("toggle_question_visibility", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    case find_question_log(game, id) do
      nil ->
        {:noreply, socket}

      q ->
        new_vis = if q.visibility == "community", do: "private", else: "community"
        Games.update_question_visibility(q, new_vis)

        grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
        conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
        threads = build_thread_summaries(grouped)
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
      socket = assign(socket, suggestions_open: false)
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
  def handle_event("pin_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    case find_question_log(game, id) do
      nil -> :ok
      q -> Games.pin_question(q)
    end

    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
    threads = build_thread_summaries(grouped)

    {:noreply,
     assign(socket,
       conversation: conversation,
       threads: threads,
       pending_count: Enum.count(threads, & &1.pending)
     )}
  end

  @impl true
  def handle_event("retry_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    cooldowns = socket.assigns.retry_cooldowns
    now = System.system_time(:second)

    if Map.get(cooldowns, id, 0) + 10 <= now do
      resubmit_question(id, socket, skip_pool: false)
    else
      {:noreply, put_flash(socket, :error, "Please wait a moment before retrying.")}
    end
  end

  @impl true
  def handle_event("regenerate_answer", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    # Discard a provisional/cached answer and force a fresh rulebook-grounded one.
    # Reset this answer's voice back to plain — old restyles no longer apply.
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

  @impl true
  def handle_event("thumbs_up", %{"id" => id_str}, socket) do
    handle_feedback(id_str, "up", socket)
  end

  @impl true
  def handle_event("thumbs_down", %{"id" => id_str}, socket) do
    handle_feedback(id_str, "down", socket)
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

    if question != "" do
      case Games.check_rate_limit(socket.assigns.current_user) do
        :ok ->
          # The answer is about to change — drop any cached persona restyles.
          RuleMaven.Voices.clear_for_question(id)

          %{game: game, included_expansions: included} = socket.assigns
          expansion_ids = Map.keys(included)

          old_q = find_question_log(game, id)
          was_pending = old_q && old_q.answer == "Thinking..."

          if old_q, do: Games.delete_question(old_q)

          visibility = if old_q, do: old_q.visibility, else: "private"

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

          case Games.log_question(%{
                 game_id: game.id,
                 question: question,
                 answer: "Thinking...",
                 user_id: socket.assigns.current_user.id,
                 visibility: visibility
               }) do
            {:ok, question_log} ->
              %{
                game_id: game.id,
                question_log_id: question_log.id,
                question: question,
                expansion_ids: expansion_ids,
                recent_context: recent,
                user_id: socket.assigns.current_user.id,
                skip_pool: skip_pool
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
               |> push_patch(to: ~p"/games/#{game.id}?t=#{question_log.id}")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to retry question")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_feedback(id_str, value, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    q = find_question_log(game, id)

    if q do
      new_feedback = if q.feedback == value, do: nil, else: value
      Games.log_question_update(q, %{feedback: new_feedback})

      updated =
        Enum.map(socket.assigns.conversation, fn msg ->
          if msg.id == id, do: Map.put(msg, :feedback, new_feedback), else: msg
        end)

      {:noreply, assign(socket, conversation: updated)}
    else
      {:noreply, socket}
    end
  end

  defp find_question_log(_game, id), do: get_question_log_by_id(id)

  defp get_question_log_by_id(id) do
    import Ecto.Query
    alias RuleMaven.Games.QuestionLog
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
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
                    question: ql.question,
                    answer: ql.answer
                }

              t ->
                t
            end)

          # If followup, rebuild threads from DB to move it under parent (remove orphan root)
          if ql.parent_question_id do
            grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
            build_thread_summaries(grouped)
          else
            updated
          end
        else
          socket.assigns.threads
        end

      # Targeted update if this thread is currently active
      conversation =
        if socket.assigns.active_thread_id == question_log_id do
          Enum.map(socket.assigns.conversation, fn
            %{id: ^question_log_id, role: :user} = msg ->
              msg
              |> Map.put(:content, ql.question)
              |> Map.put(:cleaned_question, ql.cleaned_question)
              |> Map.put(:followup, data[:followup] || false)

            %{id: ^question_log_id, role: :assistant} = msg ->
              if ql.answer == "Thinking..." do
                msg
              else
                msg
                |> Map.delete(:pending)
                |> Map.put(:content, ql.answer)
                |> Map.put(:cited_passage, ql.cited_passage)
                |> Map.put(:cited_page, data[:cited_page] || ql.cited_page)
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
              end

            msg ->
              msg
          end)
        else
          socket.assigns.conversation
        end

      pending_count = Enum.count(threads, & &1.pending)

      community = Games.community_questions(game, socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(
         conversation: conversation,
         threads: threads,
         pending_count: pending_count,
         community_questions: community,
         refresh: socket.assigns.refresh + 1
       )
       |> push_event("scroll_bottom", %{})}
    else
      {:noreply, socket}
    end
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

  def handle_info({:voice_ready, ql_id, voice, content}, socket) do
    cache = Map.put(socket.assigns.voice_cache, {ql_id, voice}, content)
    pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})
    {:noreply, assign(socket, voice_cache: cache, voice_pending: pending)}
  end

  def handle_info({:voice_failed, ql_id, voice}, socket) do
    pending = MapSet.delete(socket.assigns.voice_pending, {ql_id, voice})

    {:noreply,
     socket
     |> assign(voice_pending: pending)
     |> put_flash(:error, "Couldn't apply that voice — showing the plain answer.")}
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
          Enum.map(socket.assigns.conversation, fn
            %{id: ^question_log_id, role: :assistant} = msg ->
              msg
              |> Map.delete(:pending)
              |> Map.put(:content, "⚠️ #{data.error}")

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
         pending_count: Enum.count(threads, & &1.pending)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="chat-layout"
      data-refresh={@refresh}
      style="display:flex;flex-direction:column;height:calc(100dvh - 3.5rem);position:fixed;top:3.5rem;left:0;right:0;bottom:0;z-index:10;background:var(--bg)"
    >
      <!-- Header -->
      <div
        class="chat-header"
        style="flex-shrink:0;padding:0.35rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface)"
      >
        <div class="flex items-center justify-between" style="flex-wrap:wrap;gap:0.35rem">
          <div class="flex items-center gap-1" style="min-width:0;flex-wrap:wrap">
            <.link
              navigate={~p"/"}
              style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
            >
              &larr;
            </.link>
            <h1 class="text-sm font-bold truncate" style="max-width:300px">{@game.name}</h1>
            <%= if @game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(@game.category) do %>
              <.link
                href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
                target="_blank"
                rel="noopener"
                style="color:#ea580c;text-decoration:none;font-size:0.65rem;font-weight:600;flex-shrink:0"
              >BGG</.link>
            <% end %>
            <%= if @game.image_url do %>
              <img
                src={@game.image_url}
                alt=""
                style="width:22px;height:22px;border-radius:4px;object-fit:cover;flex-shrink:0"
              />
            <% end %>
            <%!-- Rulebook sources dropdown --%>
            <div :if={@sources != []} style="flex-shrink:0;position:relative">
              <details class="sources-dropdown">
                <summary style="cursor:pointer;list-style:none;display:flex;align-items:center;gap:0.2rem;color:var(--text-muted);font-size:0.7rem;font-weight:600;user-select:none;padding:0.2rem 0.4rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg-subtle)">
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
                            (game masters) get the extracted-text HTML view. --%>
                      <div :if={@is_admin and src.html_path} style="display:flex;gap:0.5rem">
                        <.link
                          href={~p"/rulebooks/#{src.id}/html"}
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
            </div>
          </div>
          <div class="flex items-center gap-1" style="flex-wrap:wrap">
            <button
              type="button"
              phx-click="toggle_sidebar"
              class="sidebar-toggle"
              style="background:none;border:1px solid var(--border);border-radius:0.3rem;padding:0.15rem 0.4rem;font-size:0.8rem;cursor:pointer;color:var(--text)"
            >☰</button>
            <%!-- Community --%>
            <%= if @community_count > 0 do %>
              <.link
                navigate={~p"/games/#{@game.id}/faq"}
                style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
              >
                FAQ ({@community_count})
              </.link>
            <% end %>
            <%!-- Cheat Sheet --%>
            <%= if Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil)) do %>
              <.link
                href={~p"/games/#{@game.id}/cheatsheet"}
                target="_blank"
                style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
              >
                Cheat Sheet
              </.link>
            <% end %>
            <.link
              :if={RuleMaven.Users.game_master?(@current_user)}
              navigate={~p"/games/#{@game.id}/edit"}
              style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
            >
              Edit
            </.link>
            <.link
              :if={RuleMaven.Users.game_master?(@current_user)}
              navigate={~p"/games/#{@game.id}/review"}
              style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
            >
              Review
            </.link>
          </div>
        </div>
      </div>

      <div style="display:flex;flex:1;min-height:0">
        <!-- Sidebar backdrop (mobile only) -->
        <div
          :if={@sidebar_open}
          class="sidebar-backdrop"
          phx-click="toggle_sidebar"
          style="display:none;position:fixed;top:0;left:0;right:0;bottom:0;z-index:49;background:rgba(0,0,0,0.3)"
        >
        </div>

        <!-- Question sidebar: shows all threads -->
        <div
          id="question-sidebar"
          class={"question-sidebar #{if @sidebar_open, do: "", else: "sidebar-closed"}"}
          style="flex-shrink:0;width:16rem;overflow-y:auto;border-right:1px solid var(--border);background:var(--bg-surface);padding:0.5rem 0;font-size:0.9rem;display:flex;flex-direction:column"
        >
          <div style="padding:0.35rem 0.75rem;font-size:0.78rem;font-weight:600;color:var(--text);text-transform:uppercase;display:flex;justify-content:space-between;align-items:center">
            <span>
              Questions
              <%= if @pending_count > 0 do %>
                <span style="display:inline-flex;align-items:center;justify-content:center;background:var(--accent);color:#fff;border-radius:9999px;font-size:0.55rem;font-weight:700;padding:0 0.3rem;min-width:1.1em;height:1.1em;vertical-align:middle;margin-left:0.25rem">{@pending_count}</span>
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
                  style={"display:block;text-align:left;background:none;border:none;cursor:pointer;padding:0.25rem 0.75rem;color:var(--text-secondary);font-size:0.72rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == q.id, do: "var(--accent)", else: "var(--border-subtle)"};width:100%"}
                >
                  <span style="word-break:break-word;white-space:normal;display:block;line-height:1.3">
                    {q.canonical_question || q.question}
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
            Enum.reject(@threads, fn t -> t.refused || MapSet.member?(community_ids, t.id) end) %>
          <% refused = Enum.filter(@threads, & &1.refused) %>
          <% refused_count = length(refused) %>
          <% groups = group_threads_by_time(answered) %>
          <% refused_groups = group_threads_by_time(refused) %>

          <%= for {label, key} <- [{"Today", :today}, {"Last 7 Days", :week}, {"Older", :older}] do %>
            <% items =
              Map.get(groups, key, [])
              |> Enum.filter(fn t ->
                @search_query == "" ||
                  String.contains?(String.downcase(t.question), String.downcase(@search_query))
              end) %>
            <%= if items != [] do %>
              <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
                {label}
              </div>
              <%= for t <- items do %>
                <button
                  id={"thread-#{t.id}"}
                  type="button"
                  class="sidebar-item"
                  phx-click="switch_thread"
                  phx-value-id={t.id}
                  style={"display:block;text-align:left;background:none;border:none;cursor:pointer;padding:0.22rem 0.75rem;font-size:0.73rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == t.id, do: "var(--accent)", else: "transparent"};width:100%;color:var(--text)"}
                >
                  <div style="display:flex;align-items:baseline;gap:0.2rem">
                    <%= if t.favorited do %>
                      <span style="color:#e05c2a;font-size:0.55rem;flex-shrink:0">♥</span>
                    <% end %>
                    <%= if t.pending do %>
                      <span
                        class="animate-pulse"
                        style="color:var(--accent);font-size:0.45rem;flex-shrink:0"
                      >●</span>
                    <% end %>
                    <%= if !t.pending && is_binary(t.answer) && String.starts_with?(t.answer, "⚠️") do %>
                      <span
                        style="color:var(--red,#e53e3e);font-size:0.55rem;flex-shrink:0"
                        title="Failed"
                      >⚠</span>
                    <% end %>
                    <span style="word-break:break-word;white-space:normal">{t.question}</span>
                  </div>
                </button>
              <% end %>
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
               Enum.all?(@threads, fn t -> @search_query == "" || not String.contains?(String.downcase(t.question), String.downcase(@search_query)) end) &&
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

        <!-- Messages -->
        <div
          id="chat-messages"
          class="chat-messages"
          style="flex:1;overflow-y:auto;padding:1rem;display:flex;flex-direction:column;gap:1rem;background:var(--bg);max-width:48rem;margin:0 auto;width:100%;min-width:0"
          phx-hook="ChatScroll"
        >
          <%= if @source_count == 0 do %>
            <div class="text-center text-gray-400 py-8">
              <p class="text-sm">No rulebook sources yet.</p>
              <.link
                :if={RuleMaven.Users.game_master?(@current_user)}
                navigate={~p"/games/#{@game.id}/edit"}
                style="background:var(--accent);color:#fff;text-decoration:none;font-size:0.8rem;font-weight:600;padding:0.3rem 0.75rem;border-radius:0.3rem"
              >
                Add rulebook text or PDF
              </.link>
            </div>
          <% end %>

          <%= if @conversation == [] && @source_count > 0 do %>
            <!-- Onboarding card (first visit) -->
            <div
              :if={@show_onboarding}
              style="text-align:center;padding:1.5rem 1rem;color:var(--text);max-width:32rem;margin:0 auto"
            >
              <div style="font-size:1.5rem;margin-bottom:0.75rem">🎲</div>
              <h2 style="font-size:1.15rem;font-weight:700;margin:0 0 0.5rem;color:var(--text)">
                Welcome to {@game.name} Rules
              </h2>
              <p style="font-size:0.82rem;color:var(--text-secondary);margin:0 0 1.25rem;line-height:1.5">
                Ask any rules question in plain English. Answers are grounded in the actual rulebook text with exact citations.
              </p>
              <div style="display:flex;flex-direction:column;gap:0.75rem;text-align:left;margin-bottom:1.25rem">
                <div style="display:flex;gap:0.75rem;align-items:flex-start">
                  <span style="font-size:1.1rem;flex-shrink:0">1.</span>
                  <div>
                    <div style="font-weight:600;font-size:0.82rem;color:var(--text)">
                      Ask a question
                    </div>
                    <div style="font-size:0.72rem;color:var(--text-muted)">
                      Type below. Plain English works — "Can I play a card out of turn?"
                    </div>
                  </div>
                </div>
                <div style="display:flex;gap:0.75rem;align-items:flex-start">
                  <span style="font-size:1.1rem;flex-shrink:0">2.</span>
                  <div>
                    <div style="font-weight:600;font-size:0.82rem;color:var(--text)">
                      Get a cited answer
                    </div>
                    <div style="font-size:0.72rem;color:var(--text-muted)">
                      Answers quote the rulebook. Tap the citation to see exactly where it came from.
                    </div>
                  </div>
                </div>
                <div style="display:flex;gap:0.75rem;align-items:flex-start">
                  <span style="font-size:1.1rem;flex-shrink:0">3.</span>
                  <div>
                    <div style="font-weight:600;font-size:0.82rem;color:var(--text)">
                      Upvote or follow up
                    </div>
                    <div style="font-size:0.72rem;color:var(--text-muted)">
                      👍 helpful answers. Ask follow-up questions — they'll be grouped together.
                    </div>
                  </div>
                </div>
                <%= if @community_count > 0 do %>
                  <div style="display:flex;gap:0.75rem;align-items:flex-start">
                    <span style="font-size:1.1rem;flex-shrink:0">★</span>
                    <div>
                      <div style="font-weight:600;font-size:0.82rem;color:var(--text)">
                        Browse community answers ({@community_count})
                      </div>
                      <div style="font-size:0.72rem;color:var(--text-muted)">
                        <.link
                          navigate={~p"/games/#{@game.id}/faq"}
                          style="color:var(--accent);font-weight:600"
                        >Browse FAQ</.link>
                        — curated answers from other players.
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
              <div style="display:flex;gap:0.5rem;justify-content:center">
                <button
                  type="button"
                  phx-click="dismiss_onboarding"
                  style="background:var(--accent);color:#fff;border:none;padding:0.4rem 1.5rem;border-radius:0.4rem;font-size:0.8rem;font-weight:600;cursor:pointer"
                >See suggested questions</button>
              </div>
            </div>

            <!-- Simple empty state (after onboarding dismissed) -->
            <div
              :if={!@show_onboarding}
              style="text-align:center;padding:2rem 1rem;color:var(--text-secondary);font-size:0.85rem;line-height:1.6"
            >
              <p style="font-size:1.1rem;font-weight:600;color:var(--text);margin-bottom:0.5rem">
                Ask a rules question
              </p>
              <p>Type your question below. Answers cite the exact rulebook passage.</p>

              <%= if @rule_card do %>
                <div style="margin:1.5rem auto 0;max-width:30rem;text-align:left;background:linear-gradient(135deg,var(--bg-subtle),var(--bg-surface));border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.1rem;box-shadow:0 1px 3px rgba(0,0,0,0.06)">
                  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:0.5rem">
                    <span style="font-size:0.7rem;font-weight:800;letter-spacing:0.05em;text-transform:uppercase;color:var(--accent)">
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

              <%= if @source_count > 0 do %>
                <div style="margin:1.25rem auto 0;max-width:30rem;text-align:left">
                  <%= cond do %>
                    <% @setup_checklist && (@setup_checklist["components"] != [] || @setup_checklist["setup"] != []) -> %>
                      <% total =
                        length(@setup_checklist["components"]) + length(@setup_checklist["setup"]) %>
                      <% done = MapSet.size(@checklist_done) %>
                      <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.1rem">
                        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:0.6rem">
                          <span style="font-size:0.78rem;font-weight:800;letter-spacing:0.03em;text-transform:uppercase;color:var(--text)">
                            🧩 Setup checklist
                          </span>
                          <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">
                            {done}/{total} done
                          </span>
                        </div>

                        <%= if @setup_checklist["components"] != [] do %>
                          <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.3rem 0 0.3rem">
                            Gather
                          </div>
                          <%= for {item, i} <- Enum.with_index(@setup_checklist["components"]) do %>
                            <% key = "c-#{i}" %>
                            <% checked = MapSet.member?(@checklist_done, key) %>
                            <button
                              type="button"
                              phx-click="toggle_step"
                              phx-value-key={key}
                              style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:0.2rem 0;font-size:0.82rem;line-height:1.4;color:#{if checked, do: "var(--text-muted)", else: "var(--text)"}"}
                            >
                              <span aria-hidden="true">{if checked, do: "☑️", else: "⬜"}</span>
                              <span style={if checked, do: "text-decoration:line-through", else: ""}>
                                {item}
                              </span>
                            </button>
                          <% end %>
                        <% end %>

                        <%= if @setup_checklist["setup"] != [] do %>
                          <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.6rem 0 0.3rem">
                            Steps
                          </div>
                          <%= for {step, i} <- Enum.with_index(@setup_checklist["setup"]) do %>
                            <% key = "s-#{i}" %>
                            <% checked = MapSet.member?(@checklist_done, key) %>
                            <button
                              type="button"
                              phx-click="toggle_step"
                              phx-value-key={key}
                              style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:0.3rem 0;font-size:0.82rem;line-height:1.4;color:#{if checked, do: "var(--text-muted)", else: "var(--text)"}"}
                            >
                              <span aria-hidden="true">{if checked, do: "☑️", else: "⬜"}</span>
                              <span>
                                <span style={"font-weight:600;#{if checked, do: "text-decoration:line-through", else: ""}"}>
                                  {step["title"]}
                                </span>
                                <%= if step["detail"] not in [nil, "", "nil"] do %>
                                  <span style="display:block;font-size:0.74rem;color:var(--text-muted)">
                                    {step["detail"]}
                                  </span>
                                <% end %>
                              </span>
                            </button>
                          <% end %>
                        <% end %>

                        <button
                          type="button"
                          phx-click="reset_checklist"
                          style="margin-top:0.6rem;background:none;border:1px solid var(--border);border-radius:0.3rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.5rem;color:var(--text-muted);font-weight:600"
                        >↺ Reset</button>
                      </div>

                    <% @setup_status == "generating" -> %>
                      <div style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.6rem;padding:0.75rem 1rem;font-size:0.8rem;color:var(--text-muted)">
                        🧩 Building your setup checklist…
                      </div>

                    <% @setup_status == "error" -> %>
                      <div style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.6rem;padding:0.75rem 1rem;font-size:0.8rem;color:var(--text-muted)">
                        Couldn't build the checklist.
                        <button
                          type="button"
                          phx-click="generate_setup"
                          style="margin-left:0.4rem;background:var(--accent);color:#fff;border:none;border-radius:0.3rem;font-size:0.72rem;cursor:pointer;padding:0.2rem 0.6rem;font-weight:600"
                        >Retry</button>
                      </div>

                    <% true -> %>
                      <button
                        type="button"
                        phx-click="generate_setup"
                        style="background:var(--bg-surface);border:1px dashed var(--border);border-radius:0.6rem;padding:0.6rem 1rem;font-size:0.82rem;cursor:pointer;color:var(--text);font-weight:600;width:100%"
                      >
                        🧩 Generate setup checklist
                      </button>
                  <% end %>
                </div>
              <% end %>

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
            <% is_followup = msg.role == :user && msg[:followup] %>
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
                id={"chat-msg-#{idx}"}
                class={[
                  "chat-msg",
                  msg.role == :user && "chat-msg-user",
                  is_followup && "chat-msg-followup"
                ]}
                style={"display:flex;flex-direction:column;align-items:#{if msg.role == :user, do: "flex-end", else: "flex-start"}"}
              >
                <div style={"max-width:85%;padding:0.75rem 1rem;border-radius:0.85rem;font-size:0.95rem;line-height:1.4;box-shadow:0 1px 3px rgba(0,0,0,0.08);#{if msg.role == :user, do: "background:var(--accent);color:#fff;border-bottom-right-radius:0.25rem;margin-left:auto", else: "background:var(--bg-surface);color:var(--text);border-bottom-left-radius:0.25rem"}#{if is_followup && msg.role == :user, do: ";font-size:0.85rem;opacity:0.92", else: ""}#{if is_followup && msg.role != :user, do: ";margin-left:2rem;font-size:0.85rem;opacity:0.92", else: ""}#{if msg[:refused], do: ";opacity:0.72", else: ""}"}>
                  <%= if is_followup do %>
                    <div style="font-size:0.6rem;opacity:0.6;margin-bottom:0.15rem">↳ followup</div>
                  <% end %>
                  <% stamp =
                    msg.role == :assistant && msg.content != "Thinking..." &&
                      verdict_stamp(msg[:verdict]) %>
                  <%= if stamp do %>
                    <% {emoji, label, color, bg} = stamp %>
                    <div style={"display:inline-flex;align-items:center;gap:0.3rem;margin-bottom:0.5rem;padding:0.2rem 0.55rem;border-radius:999px;background:#{bg};color:#{color};font-weight:800;font-size:0.7rem;letter-spacing:0.04em;text-transform:uppercase"}>
                      <span aria-hidden="true">{emoji}</span> {label}
                    </div>
                  <% end %>
                  <%= if msg.role == :assistant && msg[:refused] && is_nil(msg[:verdict]) do %>
                    <div style="font-size:0.6rem;opacity:0.55;margin-bottom:0.15rem;color:var(--text-muted)">
                      ⚐ not covered
                    </div>
                  <% end %>
                  <div>
                    <%= if msg.role == :assistant && msg.content == "Thinking..." do %>
                      <%= if msg[:pending] do %>
                        <span class="typing-indicator">
                          <span></span><span></span><span></span>
                        </span>
                      <% else %>
                        <div style="font-size:0.6rem;opacity:0.5;margin-bottom:0.1rem;color:var(--text-muted)">
                          No answer received
                        </div>
                      <% end %>
                    <% else %>
                      <% v_sel =
                        (msg.role == :assistant && Map.get(@voice_sel, msg[:id], "neutral")) ||
                          "neutral" %>
                      <% v_content =
                        if v_sel == "neutral",
                          do: nil,
                          else: Map.get(@voice_cache, {msg[:id], v_sel}) %>
                      <% v_pending = MapSet.member?(@voice_pending, {msg[:id], v_sel}) %>
                      <%= if v_pending && is_nil(v_content) do %>
                        <div style="font-size:0.68rem;opacity:0.7;font-style:italic;margin-bottom:0.3rem;color:var(--text-muted)">
                          🎭 putting it in character…
                        </div>
                      <% end %>
                      {render_markdown(v_content || msg.content)}
                    <% end %>
                  </div>

                  <%= if msg[:cited_passage] && msg.content != "Thinking..." do %>
                    <% on_user = msg.role == :user %>
                    <figure style={"margin:0.75rem 0 0;border-radius:0.5rem;overflow:hidden;border:1px solid #{if on_user, do: "rgba(255,255,255,0.25)", else: "var(--border)"};background:#{if on_user, do: "rgba(255,255,255,0.1)", else: "var(--bg-subtle)"}"}>
                      <%= if msg[:cited_page] do %>
                        <figcaption style={"display:flex;align-items:center;gap:0.35rem;padding:0.3rem 0.6rem;font-size:0.66rem;font-weight:700;letter-spacing:0.02em;text-transform:uppercase;border-bottom:1px solid #{if on_user, do: "rgba(255,255,255,0.15)", else: "var(--border-subtle)"};color:#{if on_user, do: "rgba(255,255,255,0.85)", else: "var(--text-muted)"}"}>
                          <span aria-hidden="true">&#128206;</span> Rulebook &middot; p.{msg.cited_page}
                        </figcaption>
                      <% end %>
                      <blockquote style={"margin:0;padding:0.55rem 0.7rem 0.55rem 0.85rem;border-left:3px solid #{if on_user, do: "rgba(255,255,255,0.5)", else: "var(--accent)"};font-style:italic;font-size:0.78rem;line-height:1.5;white-space:pre-wrap;word-break:break-word;color:#{if on_user, do: "rgba(255,255,255,0.92)", else: "var(--text)"}"}>{String.trim(msg.cited_passage)}</blockquote>
                      <%= if msg[:cited_html_link] do %>
                        <div style={"padding:0 0.7rem 0.5rem 0.85rem"}>
                          <.link
                            href={msg.cited_html_link}
                            target="_blank"
                            style={"font-size:0.72rem;font-weight:600;#{if on_user, do: "color:#fff", else: "color:var(--blue)"}"}
                          >
                            View in rulebook &rarr;
                          </.link>
                        </div>
                      <% end %>
                    </figure>
                  <% end %>

                  <!-- Citation confidence meter -->
                  <%= if msg.role == :assistant && !msg[:refused] &&
                         msg.content != "Thinking..." && !msg[:pending] &&
                         not String.starts_with?(to_string(msg.content), "⚠️") do %>
                    <% {conf_label, conf_pct, conf_color} = answer_confidence(msg) %>
                    <div
                      style="margin-top:0.6rem"
                      title={"Confidence: #{conf_label}"}
                    >
                      <div style="display:flex;align-items:center;justify-content:space-between;font-size:0.62rem;font-weight:600;color:var(--text-muted);margin-bottom:0.2rem">
                        <span>{conf_label}</span>
                        <span style={"color:#{conf_color}"}>{conf_pct}%</span>
                      </div>
                      <div style="height:4px;border-radius:999px;background:var(--border);overflow:hidden">
                        <div style={"height:100%;width:#{conf_pct}%;background:#{conf_color};border-radius:999px"}>
                        </div>
                      </div>
                    </div>
                  <% end %>

                  <!-- Followup suggestions -->
                  <%= if msg.role == :assistant && msg[:followups] != nil && msg[:followups] != [] do %>
                    <div style="margin-top:0.75rem;padding:0.6rem 0.75rem;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.5rem">
                      <div style="color:var(--text-muted);font-weight:600;margin-bottom:0.4rem;font-size:0.72rem">
                        You might also ask:
                      </div>
                      <div style="display:flex;flex-direction:column;gap:0.3rem">
                        <%= for q <- msg[:followups] do %>
                          <button
                            type="button"
                            phx-click="ask_suggestion"
                            phx-value-q={q}
                            disabled={@pending_count >= @max_concurrent}
                            style="text-align:left;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.35rem;padding:0.3rem 0.5rem;font-size:0.82rem;color:var(--text);cursor:pointer;line-height:1.35"
                          >{q}</button>
                        <% end %>
                      </div>
                    </div>
                  <% end %>

                  <!-- Also asked: other questions from same message, answered separately -->
                  <%= if msg.role == :assistant && msg[:also_asked] != nil && msg[:also_asked] != [] do %>
                    <div style="margin-top:0.75rem;padding:0.6rem 0.75rem;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.5rem;font-size:0.72rem">
                      <div style="color:var(--text-muted);font-weight:600;margin-bottom:0.4rem">
                        You also asked — tap to ask separately:
                      </div>
                      <div style="display:flex;flex-direction:column;gap:0.3rem">
                        <%= for q <- msg[:also_asked] do %>
                          <button
                            type="button"
                            phx-click="quick_ask"
                            phx-value-question={q}
                            disabled={@pending_count >= @max_concurrent}
                            style="text-align:left;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.35rem;padding:0.3rem 0.5rem;font-size:0.72rem;color:var(--text);cursor:pointer;line-height:1.35"
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

                  <!-- Pool hit badge -->
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
                </div>

                <!-- Persona voice switcher -->
                <div
                  :if={
                    msg.role == :assistant && !msg[:refused] &&
                      msg.content != "Thinking..." && !msg[:pending] &&
                      not String.starts_with?(to_string(msg.content), "⚠️")
                  }
                  style="display:flex;flex-wrap:wrap;gap:0.25rem;align-items:center;padding:0.4rem 0.25rem 0"
                >
                  <span style="font-size:0.6rem;color:var(--text-muted);font-weight:600;margin-right:0.15rem">
                    🎭 Voice:
                  </span>
                  <% cur_voice = Map.get(@voice_sel, msg[:id], "neutral") %>
                  <%= for v <- RuleMaven.Voices.all() do %>
                    <% active = cur_voice == v.id %>
                    <button
                      type="button"
                      phx-click="set_voice"
                      phx-value-id={msg[:id]}
                      phx-value-voice={v.id}
                      title={v.label}
                      style={"display:inline-flex;align-items:center;gap:0.2rem;border-radius:999px;font-size:0.65rem;cursor:pointer;padding:0.12rem 0.45rem;font-weight:600;border:1px solid #{if active, do: "var(--accent)", else: "var(--border)"};background:#{if active, do: "var(--accent)", else: "var(--bg-surface)"};color:#{if active, do: "#fff", else: "var(--text-muted)"}"}
                    >
                      <span aria-hidden="true">{v.emoji}</span>
                      <span>{v.label}</span>
                    </button>
                  <% end %>
                </div>

                <!-- Answer actions (copy + vote) -->
                <% is_community_msg =
                  MapSet.member?(MapSet.new(@community_questions, & &1.id), msg[:id]) %>
                <div
                  :if={
                    msg.role == :assistant && !msg[:refused] &&
                      msg.content != "Thinking..." && !msg[:pending] &&
                      not String.starts_with?(msg.content, "⚠️")
                  }
                  style="display:flex;gap:0.5rem;align-items:center;padding:0.25rem 0.25rem 0"
                >
                  <% q_text = find_question_for_answer(@conversation, msg) %>
                  <% plain_text = strip_markdown(msg.content) %>
                  <button
                    type="button"
                    id={"copy-btn-#{idx}"}
                    phx-hook="ClipboardCopy"
                    data-clipboard-text={"Q: #{q_text}\n\nA: #{plain_text}"}
                    style="background:none;border:1px solid var(--border);border-radius:0.25rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.4rem;color:var(--text-muted);font-weight:500"
                    title="Copy as plain text"
                  >Text</button>
                  <button
                    type="button"
                    id={"copy-md-btn-#{idx}"}
                    phx-hook="ClipboardCopy"
                    data-clipboard-text={msg.content}
                    style="background:none;border:1px solid var(--border);border-radius:0.25rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.4rem;color:var(--text-muted);font-weight:500"
                    title="Copy as markdown"
                  >MD</button>

                  <!-- Community vote buttons -->
                  <%= if is_community_msg do %>
                    <% cv = Map.get(@community_user_votes, msg[:id]) %>
                    <% counts = Map.get(@community_vote_counts, msg[:id], %{up: 0, down: 0}) %>
                    <button
                      type="button"
                      phx-click="community_vote"
                      phx-value-id={msg[:id]}
                      phx-value-vote="up"
                      style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if cv == "up", do: "1", else: "0.4"}"}
                      title={if cv == "up", do: "Remove vote", else: "Helpful"}
                    >👍</button>
                    <span
                      :if={Map.get(counts, :up, 0) > 0}
                      style="font-size:0.65rem;color:var(--text-muted);margin-left:-0.25rem"
                    >{counts[:up]}</span>
                    <button
                      type="button"
                      phx-click="community_vote"
                      phx-value-id={msg[:id]}
                      phx-value-vote="down"
                      style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if cv == "down", do: "1", else: "0.4"}"}
                      title={if cv == "down", do: "Remove vote", else: "Not helpful"}
                    >👎</button>
                    <span
                      :if={Map.get(counts, :down, 0) > 0}
                      style="font-size:0.65rem;color:var(--text-muted);margin-left:-0.25rem"
                    >{counts[:down]}</span>
                  <% else %>
                    <%= if msg[:pool_hit] && msg[:pool_provisional] && msg[:pool_source_id] do %>
                      <!-- Provisional pool hit: vote accrues to the source row -->
                      <% sid = msg[:pool_source_id] %>
                      <% cv = Map.get(@community_user_votes, sid) %>
                      <% counts = Map.get(@community_vote_counts, sid, %{up: 0, down: 0}) %>
                      <button
                        type="button"
                        phx-click="community_vote"
                        phx-value-id={sid}
                        phx-value-vote="up"
                        style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if cv == "up", do: "1", else: "0.4"}"}
                        title={if cv == "up", do: "Remove vote", else: "Helpful"}
                      >👍</button>
                      <span
                        :if={Map.get(counts, :up, 0) > 0}
                        style="font-size:0.65rem;color:var(--text-muted);margin-left:-0.25rem"
                      >{counts[:up]}</span>
                      <button
                        type="button"
                        phx-click="community_vote"
                        phx-value-id={sid}
                        phx-value-vote="down"
                        style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if cv == "down", do: "1", else: "0.4"}"}
                        title={if cv == "down", do: "Remove vote", else: "Not helpful"}
                      >👎</button>
                      <span
                        :if={Map.get(counts, :down, 0) > 0}
                        style="font-size:0.65rem;color:var(--text-muted);margin-left:-0.25rem"
                      >{counts[:down]}</span>
                      <button
                        type="button"
                        phx-click="regenerate_answer"
                        phx-value-id={msg.id}
                        style="background:none;border:1px solid var(--border);border-radius:0.25rem;font-size:0.65rem;cursor:pointer;padding:0.15rem 0.4rem;color:var(--text-muted);font-weight:500"
                        title="Generate a fresh answer from the rulebook"
                      >Regenerate</button>
                    <% else %>
                      <!-- LLM feedback (own questions only) -->
                      <button
                        :if={!msg[:pool_hit]}
                        type="button"
                        phx-click="thumbs_up"
                        phx-value-id={msg.id}
                        style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if msg[:feedback] == "up", do: "1", else: "0.4"}"}
                        title={if msg[:feedback] == "up", do: "Remove vote", else: "Helpful"}
                      >👍</button>
                      <button
                        :if={!msg[:pool_hit]}
                        type="button"
                        phx-click="thumbs_down"
                        phx-value-id={msg.id}
                        style={"background:none;border:none;font-size:1rem;cursor:pointer;opacity:#{if msg[:feedback] == "down", do: "1", else: "0.4"}"}
                        title={if msg[:feedback] == "down", do: "Remove vote", else: "Not helpful"}
                      >👎</button>
                    <% end %>
                  <% end %>
                </div>

                <!-- Category pills (community questions only) -->
                <% msg_cats =
                  if is_community_msg && msg[:id],
                    do: Map.get(@question_categories, msg[:id], []),
                    else: [] %>
                <div
                  :if={msg_cats != []}
                  style="display:flex;flex-wrap:wrap;gap:0.25rem;padding:0.15rem 0.25rem 0"
                >
                  <%= for cat <- msg_cats do %>
                    <.link
                      navigate={~p"/games/#{@game.id}/faq?category=#{cat.id}"}
                      style="font-size:0.6rem;padding:0.1rem 0.4rem;border-radius:1rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-muted);text-decoration:none"
                    >
                      {cat.name}
                    </.link>
                  <% end %>
                </div>

                <!-- Message actions (admin only) -->
                <div
                  :if={RuleMaven.Users.game_master?(@current_user) && msg.role == :assistant}
                  class="flex items-center gap-1 mt-0.5"
                  style="padding-left:0.25rem"
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
                      <!-- normal answer: full actions -->
                      <button
                        :if={!msg[:pending]}
                        type="button"
                        phx-click="retry_question"
                        phx-value-id={msg.id}
                        disabled={@pending_count >= @max_concurrent}
                        style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                        title="Re-ask"
                      >↻</button>
                      <button
                        :if={!msg[:history] && !msg[:pool_hit]}
                        type="button"
                        phx-click="toggle_question_visibility"
                        phx-value-id={msg.id}
                        title={
                          if msg[:visibility] == "community",
                            do: "Make private",
                            else: "Make community-visible"
                        }
                        style={"background:none;border:none;font-size:0.6rem;cursor:pointer;#{if msg[:visibility] == "community", do: "color:var(--accent)", else: "color:var(--text-muted)"}"}
                      >{if msg[:visibility] == "community", do: "🌐", else: "🔒"}</button>
                      <button
                        :if={!msg[:history]}
                        type="button"
                        phx-click="favorite_question"
                        phx-value-id={msg.id}
                        style={"background:none;border:none;font-size:0.65rem;cursor:pointer;#{if msg[:favorited], do: "color:#e05c2a", else: "color:var(--text-muted)"}"}
                        title={
                          if msg[:favorited],
                            do: "Unfavorite",
                            else: "Favorite — moves to top of list"
                        }
                      >{if msg[:favorited], do: "♥", else: "♡"}</button>
                      <button
                        :if={!msg[:history]}
                        type="button"
                        phx-click="pin_question"
                        phx-value-id={msg.id}
                        style={"background:none;border:none;font-size:0.6rem;cursor:pointer;#{if msg[:pinned], do: "color:var(--text)", else: "color:var(--text-muted)"}"}
                        title={if msg[:pinned], do: "Pinned", else: "Pin"}
                      >{if msg[:pinned], do: "◆", else: "◇"}</button>
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
                      <%= if RuleMaven.Users.game_master?(@current_user) && (msg[:llm_provider] || msg[:llm_model]) do %>
                        <span class="text-xs" style="color:var(--text-muted);margin-left:0.5rem">{msg[
                          :llm_provider
                        ]} &middot; {msg[:llm_model]}</span>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
                <!-- Admin debug: raw LLM response -->
                <%= if RuleMaven.Users.game_master?(@current_user) && msg.role == :assistant && msg[:raw_response] && msg.content != "Thinking..." do %>
                  <details style="margin-top:0.25rem;font-size:0.6rem;color:var(--text-muted);opacity:0.6">
                    <summary style="cursor:pointer">raw</summary>
                    <pre style="white-space:pre-wrap;word-break:break-word;margin-top:0.15rem;padding:0.25rem 0.5rem;background:var(--bg-subtle);border-radius:0.25rem;max-height:12rem;overflow-y:auto"><%= msg[:raw_response] %></pre>
                  </details>
                <% end %>
              </div>
            <% end %>
            <!-- end history else -->
          <% end %>
        </div>
      </div>

      <!-- Input -->
      <div style="flex-shrink:0;padding:0.5rem 1rem 0.75rem 1rem;border-top:1px solid var(--border);background:var(--bg-surface)">
        <%= if @suggestions != [] do %>
          <details
            style="margin-bottom:0.75rem;max-width:48rem;margin-left:auto;margin-right:auto;font-size:0.8rem"
            open={@suggestions_open}
          >
            <summary style="cursor:pointer;color:var(--text);font-weight:600;font-size:0.8rem;user-select:none">
              Suggested questions
            </summary>
            <div style="display:flex;flex-direction:column;gap:0.75rem;margin-top:0.5rem;max-height:40vh;overflow-y:auto;padding-right:0.25rem">
              <%= for cat <- @suggestions do %>
                <div>
                  <div style="font-size:0.72rem;font-weight:600;color:var(--text-secondary);text-transform:uppercase;margin-bottom:0.25rem">
                    {cat.category}
                  </div>
                  <div style="display:flex;flex-direction:column;gap:0.2rem">
                    <%= for q <- cat.questions do %>
                      <button
                        type="button"
                        phx-click="ask_suggestion"
                        phx-value-q={q}
                        disabled={@pending_count >= @max_concurrent}
                        style="text-align:left;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.3rem;padding:0.25rem 0.6rem;font-size:0.78rem;color:var(--text);cursor:pointer;white-space:normal;word-break:break-word;line-height:1.4"
                      >{q}</button>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </details>
        <% end %>
        <div style="max-width:48rem;margin:0 auto;width:100%">
          <%= if length(@expansions) > 0 do %>
            <div style="display:flex;flex-wrap:wrap;gap:0.35rem;margin-bottom:0.5rem">
              <span style="font-size:0.65rem;color:var(--text-muted);font-weight:600;align-self:center">Include:</span>
              <%= for exp <- @expansions do %>
                <label style={"cursor:pointer;font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:0.3rem;#{if Map.get(@included_expansions, exp.id), do: "background:var(--accent);color:#fff", else: "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border)"}"}>
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
          <form phx-submit="ask" class="flex gap-2" phx-hook="KeyboardSubmit" id="ask-form">
            <button
              type="button"
              phx-click="toggle_visibility"
              title={
                if @visibility == "private",
                  do: "Private — click to make public",
                  else: "Public — click to make private"
              }
              style="flex-shrink:0;background:none;border:1px solid var(--border);border-radius:2rem;padding:0.4rem 0.6rem;cursor:pointer;font-size:0.85rem;color:var(--text-muted)"
            >
              {if @visibility == "private", do: "🔒", else: "🌐"}
            </button>
            <button
              type="button"
              id="voice-ask-btn"
              phx-hook="VoiceDictation"
              data-target="ask-input"
              data-autosubmit="true"
              title="Ask by voice"
              disabled={@pending_count >= @max_concurrent || @source_count == 0}
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
              disabled={@pending_count >= @max_concurrent || @source_count == 0}
              autocomplete="off"
              id="ask-input"
              phx-hook="FocusInput"
            />
            <input type="hidden" name="visibility" value={@visibility} />
            <button
              type="submit"
              disabled={@pending_count >= @max_concurrent || @source_count == 0}
              style="background:var(--accent);color:white;border:none;padding:0.5rem 1.25rem;border-radius:2rem;font-weight:600;font-size:0.85rem;cursor:pointer"
            >
              {if @pending_count >= @max_concurrent, do: "Wait…", else: "Send"}
            </button>
          </form>
          <%= if @pending_count >= @max_concurrent do %>
            <div style="text-align:center;font-size:0.72rem;color:var(--text-muted);margin-top:0.3rem">
              {@pending_count} of {@max_concurrent} questions in progress — please wait for one to finish
            </div>
          <% end %>
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

  defp strip_markdown(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/^[-*]\s+/m, "")
  end

  # ── Verdict stamp ──
  # Maps the persisted verdict to {emoji, label, color, bg}. `nil` = no stamp.
  defp verdict_stamp("legal"), do: {"✅", "LEGAL MOVE", "#15803d", "#dcfce7"}
  defp verdict_stamp("illegal"), do: {"❌", "NOT ALLOWED", "#b91c1c", "#fee2e2"}
  defp verdict_stamp("silent"), do: {"🤔", "RULES SILENT", "#92400e", "#fef3c7"}
  defp verdict_stamp("info"), do: {"📖", "IN THE RULES", "#1e40af", "#dbeafe"}
  defp verdict_stamp(_), do: nil

  # ── Answer confidence meter ──
  # Pure heuristic from existing signals — no stored confidence column.
  # Returns {label, percent, color}.
  defp answer_confidence(msg) do
    cond do
      msg[:pool_hit] && msg[:pool_provisional] ->
        {"Unverified — single source", 45, "#d97706"}

      msg[:pool_hit] ->
        {"Community-verified", 96, "#15803d"}

      present?(msg[:cited_passage]) && msg[:cited_page] ->
        {"Cited from rulebook", 88, "#15803d"}

      present?(msg[:cited_passage]) ->
        {"Cited passage, page unconfirmed", 68, "#2563eb"}

      true ->
        {"No direct citation", 38, "#d97706"}
    end
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  # ── Random rule card ──
  # Load cached LLM facts; enqueue generation (and subscribe for the result) the
  # first time a game with published rules has none yet.
  defp load_did_you_know(game, sources, connected?) do
    case RuleMaven.Settings.get("did_you_know_#{game.id}") do
      nil ->
        if sources != [] do
          if connected? do
            Phoenix.PubSub.subscribe(
              RuleMaven.PubSub,
              RuleMaven.Workers.DidYouKnowWorker.topic(game.id)
            )
          end

          RuleMaven.Workers.DidYouKnowWorker.enqueue(game.id)
        end

        []

      json ->
        Jason.decode!(json)
    end
  end

  # Wrap a random generated fact in the shape the card template expects, or nil
  # when none have been generated yet (the card is simply hidden). Generated
  # facts have no page citation.
  defp fact_card([]), do: nil
  defp fact_card(facts), do: %{content: Enum.random(facts), page_number: nil}

  # Strip [Page N] markers and collapse whitespace for friendly card display.
  defp clean_rule_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\[Page\s*\d+\]/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
end
