defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, CheatSheet}
  alias Oban

  @max_concurrent 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       game: nil,
       question: "",
       conversation: [],
       pending_count: 0,
       pending: %{},
       source_count: 0,
       retry_cooldowns: %{},
       confirm_delete_id: nil,
       suggestions: [],
       suggestions_open: true,
       sidebar_open: false,
       visibility: "private",
       search_query: "",
       community_questions: [],
       refused_questions: [],
       faq_count: 0,
       refresh: 0,
       show_onboarding: false
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    game = Games.get_game!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
    end

    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    conversation = build_conversation(grouped)

    # Mark recent Thinking... messages as pending (in-flight), stale ones stay as-is
    recent = NaiveDateTime.utc_now() |> NaiveDateTime.add(-120, :second)

    {conversation, pending_count} =
      Enum.reduce(conversation, {[], 0}, fn
        %{role: :assistant, content: "Thinking...", timestamp: ts} = msg, {acc, count}
        when not is_nil(ts) ->
          if NaiveDateTime.compare(ts, recent) == :gt do
            {[Map.put(msg, :pending, true) | acc], count + 1}
          else
            {[msg | acc], count}
          end

        msg, {acc, count} ->
          {[msg | acc], count}
      end)

    conversation = Enum.reverse(conversation)

    sources = Games.list_documents(game)
    expansions = Games.expansions_with_documents(game)
    community = Games.community_questions(game, socket.assigns.current_user.id)
    refused_qs = Games.refused_questions(game, socket.assigns.current_user.id)
    faq_count = RuleMaven.Faq.faq_count(game)

    socket =
      assign(socket,
        game: game,
        conversation: conversation,
        sources: sources,
        expansions: expansions,
        included_expansions: %{},
        source_count: length(sources),
        question: "",
        pending_count: pending_count,
        pending: %{},
        community_questions: community,
        refused_questions: refused_qs,
        faq_count: faq_count,
        show_onboarding: conversation == [] && sources != [] && pending_count == 0
      )

    suggestions =
      case RuleMaven.Settings.get("suggestions_#{game.id}") do
        nil ->
          []

        json ->
          json
          |> Jason.decode!()
          |> Enum.map(fn %{"category" => c, "questions" => qs} ->
            %{category: c, questions: qs}
          end)
      end

    {:noreply, assign(socket, suggestions: suggestions, suggestions_open: false)}
  end

  # Build flat conversation from ALL grouped threads (supports concurrent questions).
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
        llm_provider: g.primary.llm_provider,
        llm_model: g.primary.llm_model,
        pinned: g.primary.pinned,
        faq_hit: g.primary.llm_provider == "faq",
        pool_hit: g.primary.llm_provider == "pool",
        visibility: g.primary.visibility,
        refused: g.primary.refused,
        raw_response: g.primary.raw_response,
        timestamp: g.primary.inserted_at
      }

      # Include history answers as additional assistant messages
      history_msgs =
        Enum.map(g.history, fn h ->
          %{
            id: h.id,
            role: :assistant,
            content: h.answer,
            cited_passage: h.cited_passage,
            cited_page: h.cited_page,
            llm_provider: h.llm_provider,
            llm_model: h.llm_model,
            pinned: h.pinned,
            refused: h.refused,
            raw_response: h.raw_response,
            timestamp: h.inserted_at,
            history: true
          }
        end)

      # Include followup Q&A pairs
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
            llm_provider: f.llm_provider,
            llm_model: f.llm_model,
            pinned: f.pinned,
            refused: f.refused,
            raw_response: f.raw_response,
            timestamp: f.inserted_at
          }

          [f_user, f_asst]
        end)

      [user_msg, assistant_msg | history_msgs] ++ followup_msgs
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
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

  @impl true
  def handle_event("ask", %{"question" => question} = params, socket) do
    question = String.trim(question)
    visibility = params["visibility"] || socket.assigns.visibility

    if question != "" do
      convo = socket.assigns.conversation

      # Check if already asked
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
          case check_rate_limit(socket) do
            :ok ->
              send(self(), {:ask_question, question, visibility})
              user_msg = %{role: :user, content: question, timestamp: DateTime.utc_now()}

              {:noreply,
               socket
               |> assign(
                 question: "",
                 conversation: convo ++ [user_msg],
                 pending_count: socket.assigns.pending_count + 1,
                 confirm_delete_id: nil
               )
               |> push_event("scroll_bottom", %{})}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, reason)}
          end
        end
      end
    else
      {:noreply, socket}
    end
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

    game
    |> Games.recent_questions(100)
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> :ok
      q -> Games.delete_question(q)
    end

    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    conversation = build_conversation(grouped)

    {:noreply,
     assign(socket,
       conversation: conversation,
       confirm_delete_id: nil
     )}
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

    game
    |> Games.recent_questions(200)
    |> Enum.find(&(&1.id == id))
    |> case do
      nil ->
        {:noreply, socket}

      q ->
        new_vis = if q.visibility == "community", do: "private", else: "community"
        Games.update_question_visibility(q, new_vis)

        grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
        conversation = build_conversation(grouped)
        community = Games.community_questions(game, socket.assigns.current_user.id)
        refused_qs = Games.refused_questions(game, socket.assigns.current_user.id)
        refresh = socket.assigns.refresh + 1

        {:noreply,
         assign(socket,
           conversation: conversation,
           community_questions: community,
           refused_questions: refused_qs,
           refresh: refresh
         )}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("ask_suggestion", %{"q" => q}, socket) do
    socket = assign(socket, suggestions_open: false)
    handle_event("ask", %{"question" => q}, socket)
  end

  @impl true
  def handle_event("pin_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    game
    |> Games.recent_questions(100)
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> :ok
      q -> Games.pin_question(q)
    end

    grouped = Games.grouped_questions(game, user_id: socket.assigns.current_user.id)
    conversation = build_conversation(grouped)

    {:noreply, assign(socket, conversation: conversation)}
  end

  @impl true
  def handle_event("retry_question", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    cooldowns = socket.assigns.retry_cooldowns
    now = System.system_time(:second)

    if Map.get(cooldowns, id, 0) + 10 <= now do
      question =
        socket.assigns.conversation
        |> Enum.find(&(&1.id == id && &1.role == :user))
        |> case do
          nil -> ""
          m -> m.content
        end

      if question != "" do
        case check_rate_limit(socket) do
          :ok ->
            game = socket.assigns.game

            old_q =
              game
              |> Games.recent_questions(100)
              |> Enum.find(&(&1.id == id))

            if old_q, do: Games.delete_question(old_q)

            visibility = if old_q, do: old_q.visibility, else: "private"

            # Check if old message was pending (affects count)
            old_was_pending? =
              Enum.any?(socket.assigns.conversation, fn
                %{id: ^id, pending: true} -> true
                _ -> false
              end)

            # Remove only the retried question's messages, keep everything else
            conversation =
              Enum.reject(socket.assigns.conversation, fn
                %{id: ^id} -> true
                _ -> false
              end)

            new_msgs = [
              %{id: nil, role: :user, content: question, timestamp: DateTime.utc_now()},
              %{
                id: nil,
                role: :assistant,
                content: "Thinking...",
                pending: true,
                timestamp: DateTime.utc_now()
              }
            ]

            pending_count =
              if old_was_pending? do
                socket.assigns.pending_count
              else
                socket.assigns.pending_count + 1
              end

            socket =
              assign(socket,
                conversation: conversation ++ new_msgs,
                question: "",
                pending_count: pending_count,
                pending: %{},
                confirm_delete_id: nil,
                retry_cooldowns: Map.put(cooldowns, id, now)
              )

            send(self(), {:ask_question, question, visibility})
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Please wait a moment before retrying.")}
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

  defp handle_feedback(id_str, value, socket) do
    {id, _} = Integer.parse(id_str)
    game = socket.assigns.game

    q = find_question_log(game, id)

    if q && is_nil(q.feedback) do
      Games.log_question_update(q, %{feedback: value})

      updated =
        Enum.map(socket.assigns.conversation, fn msg ->
          if msg.id == id, do: Map.put(msg, :feedback, value), else: msg
        end)

      {:noreply, assign(socket, conversation: updated)}
    else
      {:noreply, socket}
    end
  end

  defp find_question_log(game, id) do
    game
    |> Games.recent_questions(100)
    |> Enum.find(&(&1.id == id))
  end

  defp get_question_log_by_id(id) do
    import Ecto.Query
    alias RuleMaven.Games.QuestionLog
    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  @impl true
  def handle_info({:ask_question, question, visibility}, socket) do
    %{game: game, conversation: convo, included_expansions: included} = socket.assigns
    expansion_ids = Map.keys(included)

    # Collect recent Q&A pairs for followup context
    recent =
      convo
      |> Enum.reject(& &1[:pending])
      |> Enum.take(-4)
      |> Enum.chunk_every(2)
      |> Enum.filter(&(length(&1) == 2))
      |> Enum.map(fn [user, asst] -> %{q: user.content, a: asst.content} end)

    # Log question to DB so it survives refresh
    {:ok, question_log} =
      Games.log_question(%{
        game_id: game.id,
        question: question,
        answer: "Thinking...",
        user_id: socket.assigns.current_user.id,
        visibility: visibility
      })

    # Update the placeholder user message with real DB id
    updated_convo =
      Enum.map(convo, fn
        %{role: :user, content: ^question} = msg when msg.id == nil ->
          %{msg | id: question_log.id}

        msg ->
          msg
      end)

    # Append thinking placeholder with real id
    thinking_msg = %{
      id: question_log.id,
      role: :assistant,
      content: "Thinking...",
      pending: true,
      timestamp: DateTime.utc_now()
    }

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
     assign(socket,
       conversation: updated_convo ++ [thinking_msg],
       pending: Map.put(socket.assigns.pending, question_log.id, true)
     )}
  end

  def handle_info({:ask_question, question}, socket) do
    handle_info({:ask_question, question, "private"}, socket)
  end

  def handle_info({:ask_complete, data}, socket) do
    question_log_id = data.question_log_id
    game = socket.assigns.game

    # Read just this one answer from DB (not the whole conversation)
    ql = get_question_log_by_id(question_log_id)

    if ql do
      # Update matching messages in-place — no full conversation rebuild
      conversation =
        Enum.map(socket.assigns.conversation, fn
          %{id: ^question_log_id, role: :user} = msg ->
            msg
            |> Map.put(:content, ql.question)
            |> Map.put(:cleaned_question, ql.cleaned_question)
            |> Map.put(:followup, data[:followup] || false)

          %{id: ^question_log_id, role: :assistant} = msg ->
            msg
            |> Map.delete(:pending)
            |> Map.put(:content, ql.answer)
            |> Map.put(:cited_passage, ql.cited_passage)
            |> Map.put(:cited_page, data[:cited_page] || ql.cited_page)
            |> Map.put(:followups, data[:followups] || [])
            |> Map.put(:refused, ql.refused)
            |> Map.put(:raw_response, ql.raw_response)
            |> Map.put(:llm_provider, ql.llm_provider)
            |> Map.put(:llm_model, ql.llm_model)
            |> Map.put(:faq_hit, ql.llm_provider == "faq")
            |> Map.put(:pool_hit, ql.llm_provider == "pool")
            |> Map.put(:visibility, ql.visibility)

          msg ->
            msg
        end)

      updated? = conversation != socket.assigns.conversation

      pending_count =
        if updated?,
          do: max(0, socket.assigns.pending_count - 1),
          else: socket.assigns.pending_count

      # Refresh sidebar data (newly refused questions appear here)
      community = Games.community_questions(game, socket.assigns.current_user.id)
      refused_qs = Games.refused_questions(game, socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(
         conversation: conversation,
         pending_count: pending_count,
         community_questions: community,
         refused_questions: refused_qs,
         refresh: socket.assigns.refresh + 1
       )
       |> push_event("scroll_bottom", %{})}
    else
      # Question was already deleted (retry race) — do not decrement pending_count
      {:noreply, socket}
    end
  end

  def handle_info({:ask_error, %{question: _question, error: reason}}, socket) do
    error_msg = %{
      id: nil,
      role: :assistant,
      content: "⚠️ #{reason}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(
       conversation: socket.assigns.conversation ++ [error_msg],
       pending_count: max(0, socket.assigns.pending_count - 1)
     )
     |> push_event("scroll_bottom", %{})}
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
            <%= if @game.bgg_id do %>
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
            <div :if={@sources != []} style="flex-shrink:0">
              <details style="font-size:0.65rem">
                <summary style="cursor:pointer;color:var(--text-muted);font-weight:600;user-select:none">
                  ({length(@sources)})
                </summary>
                <div style="margin-top:0.25rem;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.5rem;max-width:calc(100vw - 2rem);box-shadow:0 4px 12px rgba(0,0,0,0.15);overflow-x:auto;display:inline-block">
                  <%= for src <- @sources do %>
                    <div style="padding:0.3rem 0;font-size:0.7rem;display:flex;gap:0.5rem;align-items:center">
                      <span style="color:var(--text);font-weight:500;white-space:nowrap">{src.label}</span>
                      <%= if src.pdf_path do %>
                        <.link
                          href={"/#{src.pdf_path}"}
                          target="_blank"
                          style="color:var(--blue);font-size:0.65rem;font-weight:600"
                        >
                          PDF
                        </.link>
                      <% end %>
                      <%= if src.html_path do %>
                        <.link
                          href={"/#{src.html_path}"}
                          target="_blank"
                          style="color:var(--blue);font-size:0.65rem;font-weight:600"
                        >
                          HTML
                        </.link>
                      <% end %>
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
              style="background:none;border:1px solid var(--border);border-radius:0.3rem;padding:0.15rem 0.4rem;font-size:0.8rem;cursor:pointer;color:var(--text);display:none"
            >☰</button>
            <%!-- FAQ --%>
            <%= if @faq_count > 0 do %>
              <.link
                navigate={~p"/games/#{@game.id}/faq"}
                style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
              >
                FAQ ({@faq_count})
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

        <!-- Question sidebar -->
        <div
          id="question-sidebar"
          class={"question-sidebar #{if @sidebar_open, do: "", else: "sidebar-closed"}"}
          style="flex-shrink:0;width:16rem;overflow-y:auto;border-right:1px solid var(--border);background:var(--bg-surface);padding:0.5rem 0;font-size:0.9rem;display:flex;flex-direction:column"
        >
          <div style="padding:0.35rem 0.75rem;font-size:0.78rem;font-weight:600;color:var(--text);text-transform:uppercase;display:flex;justify-content:space-between;align-items:center">
            <span>Questions</span>
            <button
              type="button"
              phx-click="toggle_sidebar"
              class="sidebar-close-btn"
              style="display:none;background:none;border:none;font-size:1rem;cursor:pointer;color:var(--text);padding:0;line-height:1"
            >✕</button>
          </div>

          <!-- Search -->
          <div style="padding:0.25rem 0.75rem 0.5rem">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search questions..."
              phx-change="search"
              style="width:100%;border:1px solid var(--border);border-radius:0.4rem;padding:0.3rem 0.5rem;font-size:0.72rem;background:var(--bg);color:var(--text)"
              autocomplete="off"
            />
          </div>

          <!-- Community questions -->
          <%= if @community_questions != [] do %>
            <div style="padding:0.35rem 0.75rem 0.15rem;font-size:0.65rem;font-weight:600;color:var(--text-muted);text-transform:uppercase">
              Community
            </div>
            <%= for q <- @community_questions do %>
              <button
                type="button"
                phx-click="ask_suggestion"
                phx-value-q={q.question}
                style="text-align:left;background:none;border:none;cursor:pointer;padding:0.35rem 0.75rem;color:var(--text-secondary);font-size:0.78rem;line-height:1.4;border-left:2px solid var(--border-subtle);width:100%"
                onmouseover="this.style.background='var(--bg-subtle)'"
                onmouseout="this.style.background='none'"
              >
                <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block">
                  {String.slice(q.question, 0, 55)}{if String.length(q.question) > 55, do: "…"}
                </span>
              </button>
            <% end %>
            <div style="padding:0.25rem 0.75rem 0.5rem;border-bottom:1px solid var(--border-subtle);margin-bottom:0.25rem">
            </div>
          <% end %>

          <!-- Refused questions -->
          <%= if @refused_questions != [] do %>
            <details style="padding:0.25rem 0.75rem">
              <summary style="font-size:0.65rem;font-weight:600;color:var(--text-muted);text-transform:uppercase;opacity:0.6;cursor:pointer;user-select:none">
                Not covered ({length(@refused_questions)})
              </summary>
              <div style="margin-top:0.25rem">
                <%= for q <- @refused_questions do %>
                  <div style="text-align:left;padding:0.35rem 0.75rem;color:var(--text-muted);font-size:0.75rem;line-height:1.4;border-left:2px solid var(--border-subtle);width:100%;opacity:0.5">
                    <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block">
                      ⚐ {String.slice(q.question, 0, 52)}{if String.length(q.question) > 52, do: "…"}
                    </span>
                  </div>
                <% end %>
              </div>
            </details>
            <div style="padding:0.25rem 0.75rem 0.5rem;border-bottom:1px solid var(--border-subtle);margin-bottom:0.25rem">
            </div>
          <% end %>
          <%= for {msg, idx} <- @conversation |> Enum.with_index() |> Enum.reverse() |> Enum.filter(fn {msg, _} -> msg.role == :user && !msg[:refused] && !msg[:pending] end) |> Enum.filter(fn {msg, _} -> @search_query == "" || String.contains?(String.downcase(msg.content), String.downcase(@search_query)) end) do %>
            <button
              type="button"
              id={"sidebar-q-#{idx}"}
              phx-click="toggle_sidebar"
              phx-hook="ScrollToMessage"
              data-target={"chat-msg-#{idx}"}
              style="text-align:left;background:none;border:none;cursor:pointer;padding:0.45rem 0.75rem;color:var(--text);font-size:0.9rem;line-height:1.45;border-left:2px solid transparent;width:100%"
              onmouseover="this.style.background='var(--bg-subtle)'"
              onmouseout="this.style.background='none'"
            >
              <%= if msg[:feedback] == "down" do %>
                <span style="color:var(--red);margin-right:0.15rem">👎</span>
              <% end %>
              <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block">
                {String.slice(msg.content, 0, 55)}{if String.length(msg.content) > 55, do: "…"}
              </span>
            </button>
          <% end %>

          <!-- Refused current-thread questions (dimmed) -->
          <%= for {msg, idx} <- @conversation |> Enum.with_index() |> Enum.reverse() |> Enum.filter(fn {msg, _} -> msg.role == :user && msg[:refused] end) do %>
            <button
              type="button"
              id={"sidebar-q-#{idx}"}
              phx-click="toggle_sidebar"
              phx-hook="ScrollToMessage"
              data-target={"chat-msg-#{idx}"}
              style="text-align:left;background:none;border:none;cursor:pointer;padding:0.35rem 0.75rem;color:var(--text-muted);font-size:0.75rem;line-height:1.4;border-left:2px solid var(--border-subtle);width:100%;opacity:0.5"
              onmouseover="this.style.background='var(--bg-subtle)';this.style.opacity='0.8'"
              onmouseout="this.style.background='none';this.style.opacity='0.5'"
            >
              <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block">
                ⚐ {String.slice(msg.content, 0, 52)}{if String.length(msg.content) > 52, do: "…"}
              </span>
            </button>
          <% end %>
          <div
            :if={@conversation == []}
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
                <%= if @faq_count > 0 do %>
                  <div style="display:flex;gap:0.75rem;align-items:flex-start">
                    <span style="font-size:1.1rem;flex-shrink:0">★</span>
                    <div>
                      <div style="font-weight:600;font-size:0.82rem;color:var(--text)">
                        Browse the FAQ ({@faq_count} entries)
                      </div>
                      <div style="font-size:0.72rem;color:var(--text-muted)">
                        <.link
                          navigate={~p"/games/#{@game.id}/faq"}
                          style="color:var(--accent);font-weight:600"
                        >View official FAQ</.link>
                        for curated answers to common questions.
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
            <div
              id={"chat-msg-#{idx}"}
              class={[
                "chat-msg",
                msg.role == :user && "chat-msg-user",
                is_followup && "chat-msg-followup"
              ]}
              style={"display:flex;flex-direction:column;align-items:#{if msg.role == :user, do: "flex-end", else: "flex-start"}"}
            >
              <div style={"max-width:85%;padding:0.75rem 1rem;border-radius:0.85rem;font-size:0.95rem;line-height:1.4;box-shadow:0 1px 3px rgba(0,0,0,0.08);#{if msg.role == :user, do: "background:var(--accent);color:#fff;border-bottom-right-radius:0.25rem;margin-left:auto", else: "background:var(--bg-surface);color:var(--text);border-bottom-left-radius:0.25rem"}#{if is_followup, do: ";margin-left:2rem;font-size:0.85rem;opacity:0.92", else: ""}#{if msg[:refused], do: ";opacity:0.72", else: ""}"}>
                <%= if is_followup do %>
                  <div style="font-size:0.6rem;opacity:0.6;margin-bottom:0.15rem">↳ followup</div>
                <% end %>
                <%= if msg.role == :assistant && msg[:refused] do %>
                  <div style="font-size:0.6rem;opacity:0.55;margin-bottom:0.15rem;color:var(--text-muted)">
                    ⚐ not covered
                  </div>
                <% end %>
                <div>
                  <%= if msg.role == :assistant && msg.content == "Thinking..." do %>
                    <%= if msg[:pending] do %>
                      <div class="animate-pulse" style="color:var(--text-secondary)">
                        Thinking...
                      </div>
                    <% else %>
                      <div style="font-size:0.6rem;opacity:0.5;margin-bottom:0.1rem;color:var(--text-muted)">
                        No answer received
                      </div>
                    <% end %>
                  <% else %>
                    {render_markdown(msg.content)}
                  <% end %>
                </div>

                <%= if msg[:cited_passage] && msg.content != "Thinking..." do %>
                  <div style={"margin-top:0.75rem;padding:0.5rem 0 0 0;border-top:1px solid #{if msg.role == :user, do: "rgba(255,255,255,0.3)", else: "var(--border-strong)"};font-size:0.78rem;line-height:1.45;#{if msg.role == :user, do: "color:rgba(255,255,255,0.9)", else: "color:var(--text)"}"}>
                    <%= if msg[:cited_page] do %>
                      <span style="font-weight:700">p.{msg.cited_page}</span> &mdash;
                    <% end %>
                    <span class="italic">{msg.cited_passage}</span>
                    <%= if msg[:cited_html_link] do %>
                      <div style="margin-top:0.35rem">
                        <.link
                          href={msg.cited_html_link}
                          target="_blank"
                          style={"font-size:0.72rem;font-weight:600;#{if msg.role == :user, do: "color:#fff", else: "color:var(--blue)"}"}
                        >
                          View in rulebook &rarr;
                        </.link>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <!-- Followup suggestions -->
                <%= if msg.role == :assistant && msg[:followups] != nil && msg[:followups] != [] do %>
                  <div style="margin-top:0.5rem;display:flex;flex-wrap:wrap;gap:0.3rem">
                    <span style="font-size:0.6rem;color:var(--text-muted);align-self:center">Related:</span>
                    <%= for q <- msg[:followups] do %>
                      <button
                        type="button"
                        phx-click="ask_suggestion"
                        phx-value-q={q}
                        style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.3rem;padding:0.15rem 0.35rem;font-size:0.6rem;color:var(--text-secondary);cursor:pointer"
                      >{q}</button>
                    <% end %>
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
                        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                      >Setup</button>
                      <button
                        type="button"
                        phx-click="ask_suggestion"
                        phx-value-q="How do turns work?"
                        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                      >Turn order</button>
                      <button
                        type="button"
                        phx-click="ask_suggestion"
                        phx-value-q="How does scoring work?"
                        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                      >Scoring</button>
                      <button
                        type="button"
                        phx-click="ask_suggestion"
                        phx-value-q="What are the win conditions?"
                        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.25rem;padding:0.15rem 0.4rem;font-size:0.65rem;color:var(--text);cursor:pointer"
                      >Win conditions</button>
                    </div>
                  </div>
                <% end %>

                <!-- FAQ badge -->
                <div
                  :if={msg[:faq_hit] && msg.content != "Thinking..."}
                  style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:var(--green)"
                >
                  ✅ FAQ &mdash; instant answer
                </div>

                <!-- Pool hit badge -->
                <div
                  :if={msg[:pool_hit]}
                  style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:var(--blue)"
                >
                  💬 Community answer &mdash; from question pool
                </div>

                <!-- Thumbs up/down (LLM answers only) -->
                <div
                  :if={
                    msg.role == :assistant && !msg[:faq_hit] && !msg[:pool_hit] && !msg[:refused] &&
                      msg.content != "Thinking..." && !msg[:pending]
                  }
                  style="margin-top:0.5rem;display:flex;gap:0.5rem;align-items:center"
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
                  <button
                    :if={msg[:feedback] != "down"}
                    type="button"
                    phx-click="thumbs_up"
                    phx-value-id={msg.id}
                    disabled={msg[:feedback] != nil}
                    style="background:none;border:none;font-size:1rem;cursor:pointer;opacity:0.5"
                    title="Helpful"
                  >👍</button>
                  <button
                    :if={msg[:feedback] != "up"}
                    type="button"
                    phx-click="thumbs_down"
                    phx-value-id={msg.id}
                    disabled={msg[:feedback] != nil}
                    style="background:none;border:none;font-size:1rem;cursor:pointer;opacity:0.5"
                    title="Not helpful"
                  >👎</button>
                  <%= if msg[:feedback] do %>
                    <span style="font-size:0.65rem;color:var(--text-muted)">Thanks!</span>
                  <% end %>
                </div>
              </div>

              <!-- Message actions (admin only) -->
              <div
                :if={
                  RuleMaven.Users.game_master?(@current_user) && msg.role == :assistant &&
                    msg.content != "Thinking..."
                }
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
                  <%= if msg[:refused] do %>
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
                    <button
                      type="button"
                      phx-click="retry_question"
                      phx-value-id={msg.id}
                      disabled={@pending_count >= @max_concurrent}
                      style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                      title="Re-ask"
                    >↻</button>
                    <button
                      :if={!msg[:history] && !msg[:faq_hit] && !msg[:pool_hit]}
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
                      phx-click="pin_question"
                      phx-value-id={msg.id}
                      style={"background:none;border:none;font-size:0.6rem;cursor:pointer;#{if msg[:pinned], do: "color:var(--accent)", else: "color:var(--text-muted)"}"}
                      title={if msg[:pinned], do: "Pinned", else: "Pin"}
                    >★</button>
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
          <form phx-submit="ask" class="flex gap-2">
            <input
              type="text"
              name="question"
              value={@question}
              placeholder={
                if @source_count > 0,
                  do: "Ask a rules question...",
                  else: "Add rulebook text to start asking..."
              }
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
              {if @pending_count >= @max_concurrent, do: "Wait...", else: "Send"}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp check_rate_limit(socket) do
    user = socket.assigns.current_user

    if RuleMaven.Users.game_master?(user) do
      :ok
    else
      now = DateTime.utc_now()
      daily_since = DateTime.add(now, -1, :day)
      weekly_since = DateTime.add(now, -7, :day)
      monthly_since = DateTime.add(now, -30, :day)

      daily_count = Games.recent_question_count(user.id, daily_since)
      weekly_count = Games.recent_question_count(user.id, weekly_since)
      monthly_count = Games.recent_question_count(user.id, monthly_since)

      daily_limit = rate_limit_setting("rate_limit_daily", 50)
      weekly_limit = rate_limit_setting("rate_limit_weekly", 200)
      monthly_limit = rate_limit_setting("rate_limit_monthly", 500)

      cond do
        daily_count >= daily_limit ->
          {:error, "Daily question limit reached (#{daily_limit})."}

        weekly_count >= weekly_limit ->
          {:error, "Weekly question limit reached (#{weekly_limit})."}

        monthly_count >= monthly_limit ->
          {:error, "Monthly question limit reached (#{monthly_limit})."}

        true ->
          :ok
      end
    end
  end

  defp rate_limit_setting(key, default) do
    case RuleMaven.Settings.get(key) do
      nil ->
        default

      val ->
        case Integer.parse(to_string(val)) do
          {n, _} -> n
          :error -> default
        end
    end
  end

  # ── Helpers ──

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
