defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, CheatSheet}
  alias Oban

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       game: nil,
       question: "",
       conversation: [],
       loading: false,
       source_count: 0,
       retry_cooldowns: %{},
        confirm_delete_id: nil,
        suggestions: [],
        suggestions_open: true,
        sidebar_open: false
      )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    game = Games.get_game!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
    end

    grouped = Games.grouped_questions(game)
    conversation = build_conversation(grouped)
    sources = Games.list_documents(game)
    expansions = Games.expansions_with_documents(game)

    socket =
      assign(socket,
        game: game,
        conversation: conversation,
        sources: sources,
        expansions: expansions,
        included_expansions: %{},
        source_count: length(sources),
        question: "",
        loading: false
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

  # Build flat conversation list from grouped questions
  defp build_conversation(grouped) do
    grouped
    |> Enum.flat_map(fn g ->
      user_msg = %{
        id: g.primary.id,
        role: :user,
        content: g.primary.question,
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
            timestamp: h.inserted_at,
            history: true
          }
        end)

      [user_msg, assistant_msg | history_msgs]
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
  def handle_event("ask", %{"question" => question}, socket) do
    question = String.trim(question)

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
        case check_rate_limit(socket) do
          :ok ->
            user_msg = %{role: :user, content: question, timestamp: DateTime.utc_now()}

            {:noreply,
             socket
             |> assign(
               question: "",
               conversation: convo ++ [user_msg],
               loading: true,
               confirm_delete_id: nil
             )
             |> push_event("scroll_bottom", %{})
             |> then(fn s ->
               send(self(), {:ask_question, question})
               s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
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

    grouped = Games.grouped_questions(game)
    conversation = build_conversation(grouped)

    {:noreply,
     assign(socket,
       conversation: conversation,
       confirm_delete_id: nil
     )}
  end

  @impl true
  def handle_event("cancel_delete_question", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
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

    grouped = Games.grouped_questions(game)
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
            socket =
              assign(socket,
                question: "",
                loading: true,
                confirm_delete_id: nil,
                retry_cooldowns: Map.put(cooldowns, id, now)
              )

            send(self(), {:ask_question, question})
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

  @impl true
  def handle_info({:ask_question, question}, socket) do
    %{game: game, conversation: convo, included_expansions: included} = socket.assigns
    expansion_ids = Map.keys(included)

    # Collect recent Q&A pairs for followup context
    recent =
      convo
      |> Enum.take(-4)
      |> Enum.chunk_every(2)
      |> Enum.filter(&(length(&1) == 2))
      |> Enum.map(fn [user, asst] -> %{q: user.content, a: asst.content} end)

    # Log the question immediately so it survives a refresh
    {:ok, question_log} =
      Games.log_question(%{
        game_id: game.id,
        question: question,
        answer: "Thinking...",
        user_id: socket.assigns.current_user.id
      })

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

    {:noreply, socket}
  end

  def handle_info({:ask_complete, data}, socket) do
    %{game: game} = socket.assigns

    # Rebuild conversation from DB so answer updates survive refresh
    grouped = Games.grouped_questions(game)
    conversation = build_conversation(grouped)

    # Keep loading state only if we also have a pending broadcast
    loading = conversation |> Enum.any?(&(&1.role == :assistant && &1.content == "Thinking..."))

    # Tag the preceding user message as followup if LLM says so
    conversation =
      if data.followup do
        List.update_at(conversation, -2, fn msg -> Map.put(msg, :followup, true) end)
      else
        conversation
      end

    {:noreply,
     socket
     |> assign(conversation: conversation, loading: loading)
     |> push_event("scroll_bottom", %{})}
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
     |> assign(conversation: socket.assigns.conversation ++ [error_msg], loading: false)
     |> push_event("scroll_bottom", %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="chat-layout"
      style="display:flex;flex-direction:column;height:calc(100dvh - 3.5rem);position:fixed;top:3.5rem;left:0;right:0;bottom:0;z-index:10;background:var(--bg)"
    >
      <!-- Header -->
      <div
        class="chat-header"
        style="flex-shrink:0;padding:0.35rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface)"
      >
        <div class="flex items-center justify-between" style="flex-wrap:wrap;gap:0.35rem">
          <div class="flex items-center gap-1" style="min-width:0;flex-wrap:wrap">
            <.link navigate={~p"/"} class="text-blue-600 hover:underline text-sm font-semibold" style="flex-shrink:0">
              &larr;
            </.link>
            <h1 class="text-sm font-bold truncate" style="max-width:140px">{@game.name}</h1>
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
            <div :if={@sources != []} style="position:relative;flex-shrink:0">
              <details style="font-size:0.65rem">
                <summary style="cursor:pointer;color:var(--text-muted);font-weight:600;user-select:none">
                  ({length(@sources)})
                </summary>
                <div style="position:absolute;top:100%;left:0;margin-top:0.25rem;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.5rem;min-width:180px;z-index:20;box-shadow:0 4px 12px rgba(0,0,0,0.15)">
                  <%= for src <- @sources do %>
                    <div style="padding:0.3rem 0;font-size:0.7rem;display:flex;gap:0.5rem;align-items:center;white-space:nowrap">
                      <span style="color:var(--text);font-weight:500">{src.label}</span>
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
            <%!-- Cheat Sheet --%>
            <%= if Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil)) do %>
              <.link
                href={~p"/games/#{@game.id}/cheatsheet"}
                target="_blank"
                class="text-xs text-blue-500 hover:underline font-semibold"
              >
                Cheat Sheet
              </.link>
            <% end %>
            <.link
              :if={RuleMaven.Users.game_master?(@current_user)}
              navigate={~p"/games/#{@game.id}/edit"}
              class="text-blue-600 hover:underline text-xs font-semibold"
              style="flex-shrink:0"
            >
              Edit
            </.link>
            <.link
              :if={RuleMaven.Users.game_master?(@current_user)}
              navigate={~p"/games/#{@game.id}/review"}
              class="text-blue-600 hover:underline text-xs font-semibold"
              style="flex-shrink:0"
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
          <%= for {msg, idx} <- @conversation |> Enum.with_index() |> Enum.reverse() |> Enum.filter(fn {msg, _} -> msg.role == :user end) do %>
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
                class="text-blue-600 hover:underline text-sm"
              >
                Add rulebook text or PDF
              </.link>
            </div>
          <% end %>

          <%= if @conversation == [] && @source_count > 0 do %>
            <div style="text-align:center;padding:2rem 1rem;color:var(--text-secondary);font-size:0.85rem;line-height:1.6">
              <p style="font-size:1.1rem;font-weight:600;color:var(--text);margin-bottom:0.5rem">
                Ask a rules question
              </p>
              <p>Type your question below. Answers cite the exact rulebook passage.</p>
              <%= if @suggestions != [] do %>
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

          <%= for {msg, idx} <- Enum.with_index(@conversation) do %>
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
              <div style={"max-width:85%;padding:0.75rem 1rem;border-radius:0.85rem;font-size:0.95rem;line-height:1.4;box-shadow:0 1px 3px rgba(0,0,0,0.08);#{if msg.role == :user, do: "background:var(--accent);color:#fff;border-bottom-right-radius:0.25rem;margin-left:auto", else: "background:var(--bg-surface);color:var(--text);border-bottom-left-radius:0.25rem"}#{if is_followup, do: ";margin-left:2rem;font-size:0.85rem;opacity:0.92", else: ""}"}>
                <%= if is_followup do %>
                  <div style="font-size:0.6rem;opacity:0.6;margin-bottom:0.15rem">↳ followup</div>
                <% end %>
                <div>{render_markdown(msg.content)}</div>

                <%= if msg[:cited_passage] do %>
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

                <!-- FAQ badge -->
                <div
                  :if={msg[:faq_hit]}
                  style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:var(--green)"
                >
                  ✅ FAQ &mdash; instant answer
                </div>

                <!-- Thumbs up/down (LLM answers only, not FAQ) -->
                <div
                  :if={msg.role == :assistant && !msg[:faq_hit]}
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
                :if={RuleMaven.Users.game_master?(@current_user) && msg.role == :assistant}
                class="flex items-center gap-1 mt-0.5"
                style="padding-left:0.25rem"
              >
                <button
                  type="button"
                  phx-click="retry_question"
                  phx-value-id={msg.id}
                  disabled={@loading}
                  style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                  title="Re-ask"
                >↻</button>
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
              </div>
            </div>
          <% end %>

          <!-- Loading indicator -->
          <div :if={@loading} class="chat-msg" style="display:flex;align-items:flex-start">
            <div
              class="animate-pulse"
              style="background:var(--bg-surface);color:var(--text-secondary);padding:0.6rem 0.85rem;border-radius:0.85rem;border-bottom-left-radius:0.25rem;font-size:0.875rem;box-shadow:0 1px 3px rgba(0,0,0,0.06)"
            >
              Thinking...
            </div>
          </div>
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
              disabled={@loading || @source_count == 0}
              autocomplete="off"
              id="ask-input"
              phx-hook="FocusInput"
            />
            <button
              type="submit"
              disabled={@loading || @source_count == 0}
              style="background:var(--accent);color:white;border:none;padding:0.5rem 1.25rem;border-radius:2rem;font-weight:600;font-size:0.85rem;cursor:pointer"
            >
              {if @loading, do: "...", else: "Send"}
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
