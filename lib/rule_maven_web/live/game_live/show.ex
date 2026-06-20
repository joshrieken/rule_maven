defmodule RuleMavenWeb.GameLive.Show do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, CheatSheet}

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
       confirm_delete_id: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    game = Games.get_game!(id)
    grouped = Games.grouped_questions(game)
    conversation = build_conversation(grouped)
    sources = Games.list_documents(game)

    {:noreply,
     assign(socket,
       game: game,
       conversation: conversation,
       sources: sources,
       source_count: length(sources),
       question: "",
       loading: false
     )}
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
             |> assign(question: "", conversation: convo ++ [user_msg], loading: true)
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
    %{game: game, conversation: convo} = socket.assigns

    result =
      try do
        case RuleMaven.LLM.ask(game, question) do
          {:ok, %{answer: answer} = llm_result} ->
            passage = llm_result[:cited_passage]
            citation = find_citation_link(game, passage)

            Games.log_question(%{
              game_id: game.id,
              question: question,
              answer: answer,
              cited_passage: passage,
              llm_provider: llm_result[:provider],
              llm_model: llm_result[:model],
              user_id: socket.assigns.current_user.id,
              cited_page: citation[:page],
              question_embedding: llm_result[:question_embedding]
            })

            {:ok, answer, passage, llm_result, citation}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          require Logger
          Logger.error("Chat error: #{Exception.format(:error, e, __STACKTRACE__)}")
          {:error, "Something went wrong: #{Exception.message(e)}"}
      end

    case result do
      {:ok, answer, passage, llm_result, citation} ->
        assistant_msg = %{
          id: nil,
          role: :assistant,
          content: answer,
          cited_passage: passage,
          cited_page: citation[:page],
          llm_provider: llm_result[:provider],
          llm_model: llm_result[:model],
          cited_html_link: citation[:link],
          faq_hit: llm_result[:faq_hit] || false,
          timestamp: DateTime.utc_now()
        }

        {:noreply,
         socket
         |> assign(conversation: convo ++ [assistant_msg], loading: false)
         |> push_event("scroll_bottom", %{})}

      {:error, reason} ->
        error_msg = %{
          id: nil,
          role: :assistant,
          content: "⚠️ #{reason}",
          timestamp: DateTime.utc_now()
        }

        {:noreply,
         socket
         |> assign(conversation: convo ++ [error_msg], loading: false)
         |> push_event("scroll_bottom", %{})}
    end
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
        style="flex-shrink:0;padding:0.5rem 1rem;border-bottom:1px solid var(--border);background:var(--bg-surface)"
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.link navigate={~p"/"} class="text-blue-600 hover:underline text-sm font-semibold">
              &larr; Games
            </.link>
            <h1 class="text-base font-bold truncate">{@game.name}</h1>
            <%= if @game.image_url do %>
              <img
                src={@game.image_url}
                alt=""
                style="width:28px;height:28px;border-radius:4px;object-fit:cover"
              />
            <% end %>
            <%!-- Rulebook sources dropdown --%>
            <div :if={@sources != []} style="position:relative">
              <details style="font-size:0.7rem">
                <summary style="cursor:pointer;color:var(--text-muted);font-weight:600;user-select:none">
                  Rulebooks ({length(@sources)})
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
          <div class="flex items-center gap-3">
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
              class="text-blue-600 hover:underline text-sm"
            >
              Edit
            </.link>
            <.link
              :if={RuleMaven.Users.game_master?(@current_user)}
              navigate={~p"/games/#{@game.id}/review"}
              class="text-blue-600 hover:underline text-sm"
            >
              Review
            </.link>
          </div>
        </div>
      </div>

      <!-- Messages -->
      <div
        id="chat-messages"
        class="chat-messages"
        style="flex:1;overflow-y:auto;padding:1rem;display:flex;flex-direction:column;gap:1rem;background:var(--bg);max-width:48rem;margin:0 auto;width:100%"
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

        <%= for msg <- @conversation do %>
          <div
            class={["chat-msg", msg.role == :user && "chat-msg-user"]}
            style={"display:flex;flex-direction:column;align-items:#{if msg.role == :user, do: "flex-end", else: "flex-start"}"}
          >
            <div style={"max-width:85%;padding:0.6rem 0.85rem;border-radius:0.85rem;font-size:0.875rem;line-height:1.55;box-shadow:0 1px 3px rgba(0,0,0,0.08);#{if msg.role == :user, do: "background:var(--accent);color:#fff;border-bottom-right-radius:0.25rem;margin-left:auto", else: "background:var(--bg-surface);color:var(--text);border-bottom-left-radius:0.25rem"}"}>
              <div class="whitespace-pre-wrap">{msg.content}</div>

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

              <!-- FAQ badge -->
              <div
                :if={msg[:faq_hit]}
                style="margin-top:0.5rem;font-size:0.7rem;font-weight:600;color:#16a34a"
              >
                ✅ FAQ &mdash; instant answer
              </div>

              <!-- Thumbs up/down (LLM answers only, not FAQ) -->
              <div
                :if={msg.role == :assistant && !msg[:faq_hit]}
                style="margin-top:0.5rem;display:flex;gap:0.5rem;align-items:center"
              >
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
                <span class="text-xs" style="color:#dc2626">Delete?</span>
                <button
                  type="button"
                  phx-click="confirm_delete_question"
                  phx-value-id={msg.id}
                  style="color:#dc2626;background:none;border:none;font-size:0.6rem;font-weight:600;cursor:pointer"
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

      <!-- Input -->
      <div style="flex-shrink:0;padding:0.75rem 1rem;border-top:1px solid var(--border);background:var(--bg-surface)">
        <div style="max-width:48rem;margin:0 auto;width:100%">
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
              autofocus
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

  defp find_citation_link(game, passage) do
    if passage do
      sources = Games.list_rulebook_sources(game)
      search = String.trim(passage, ~s("' \n))

      sources
      |> Enum.filter(& &1.html_path)
      |> Enum.find_value(fn source ->
        find_in_text(source.full_text, search, source.html_path)
      end)
    end
  end

  defp find_in_text(full_text, search, html_path) do
    pages = String.split(full_text, "\f")

    Enum.find_value(pages |> Enum.with_index(1), fn {page_text, page_num} ->
      paragraphs = String.split(page_text, ~r{\n\s*\n})

      para_idx =
        paragraphs
        |> Enum.with_index(1)
        |> Enum.find_value(fn {para, idx} ->
          if String.contains?(para, search) or
               String.contains?(search, String.slice(para, 0, 40)) do
            idx
          end
        end)

      if para_idx do
        %{link: "/#{html_path}#p#{para_idx}", page: page_num}
      end
    end) || nil
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
end
