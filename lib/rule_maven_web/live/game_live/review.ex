defmodule RuleMavenWeb.GameLive.Review do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMavenWeb.GameLive.{SubBar, ToolHost, ToolPanel}

  @tool_events ToolHost.events()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game_by_token(id)
    is_admin = RuleMaven.Users.can?(socket.assigns.current_user, :admin)

    cond do
      is_nil(game) ->
        {:ok, socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      !is_admin ->
        {:ok, push_navigate(socket, to: ~p"/games/#{id}/community")}

      true ->
        socket =
          socket
          |> assign(
            game: game,
            is_admin: is_admin,
            sources: Games.list_documents(game),
            documents: Games.list_documents(game),
            community_questions: Games.faq_questions(game, 100),
            categories: Games.list_game_categories(game),
            page_title: "Review — #{game.name}"
          )
          |> ToolHost.mount_header(game)
          |> ToolHost.mount_tools(game)

        {:ok, socket}
    end
  end

  # Table tools (sub-bar → floating windows) are shared by every game screen.
  @impl true
  def handle_event(event, params, socket) when event in @tool_events,
    do: ToolHost.handle_tool_event(event, params, socket)

  @impl true
  def handle_event("approve_doc", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      doc = Games.get_document!(id)
      Games.approve_document(doc, socket.assigns.current_user)
    end

    {:noreply, assign(socket, documents: Games.list_documents(socket.assigns.game))}
  end

  @impl true
  def handle_event("reject_doc", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      doc = Games.get_document!(id)
      Games.reject_document(doc, socket.assigns.current_user)
    end

    {:noreply, assign(socket, documents: Games.list_documents(socket.assigns.game))}
  end

  @impl true
  def handle_event("reject", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      Games.set_question_visibility(id, "private")
    end

    {:noreply, assign(socket, community_questions: Games.faq_questions(socket.assigns.game, 100))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game.image_url} />
    <div style="max-width:48rem;margin:0 auto;padding:1.5rem 1rem;position:relative;z-index:1">
      <SubBar.game_header
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        on_game_page={false}
      />

      <h1 class="text-xl font-bold mb-6">Review — {@game.name}</h1>

      <!-- Documents (admin only) -->
      <%= if @is_admin do %>
        <h2 class="text-lg font-semibold mt-2 mb-3">Documents</h2>
        <div style="display:flex;flex-direction:column;gap:0.75rem;margin-bottom:2rem">
          <%= for doc <- @documents do %>
            <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-surface)">
              <div class="flex items-center justify-between">
                <div>
                  <span class="font-semibold">{doc.label}</span>
                  <span style={"margin-left:0.5rem;font-size:0.75rem;padding:0.15rem 0.4rem;border-radius:0.25rem;#{status_color(doc.status)}"}>
                    {doc.status}
                  </span>
                </div>
                <div style="display:flex;gap:0.4rem">
                  <button
                    :if={doc.status != "published"}
                    phx-click="approve_doc"
                    phx-value-id={doc.id}
                    class="btn-primary btn-sm"
                  >Approve</button>
                  <button
                    :if={doc.status != "rejected"}
                    phx-click="reject_doc"
                    phx-value-id={doc.id}
                    class="btn-sm"
                  >Reject</button>
                </div>
              </div>
            </div>
          <% end %>
          <div :if={@documents == []} class="text-sm" style="color:var(--text-muted)">
            No documents yet.
          </div>
        </div>
      <% end %>

      <!-- Community Q&A -->
      <h2 class="text-lg font-semibold mb-3">Community Q&A</h2>
      <div style="display:flex;flex-direction:column;gap:0.75rem">
        <%= for q <- @community_questions do %>
          <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-surface)">
            <div class="flex items-start justify-between gap-3">
              <div class="flex-1" style="min-width:0">
                <div class="font-semibold text-sm" style="word-break:break-word">
                  {QuestionLog.display_question(q)}
                </div>
                <div
                  class="text-xs mt-1"
                  style="color:var(--text-muted);line-height:1.4;word-break:break-word"
                >
                  {String.slice(q.canonical_answer || q.answer || "", 0, 180)}
                </div>
                <%= if q.canonical_question do %>
                  <span style="font-size:0.65rem;color:var(--accent-ink, var(--accent));margin-top:0.25rem;display:block">★ curated</span>
                <% end %>
              </div>
              <%= if @is_admin do %>
                <button
                  phx-click="reject"
                  phx-value-id={q.id}
                  class="btn-icon btn-xs"
                  style="flex-shrink:0"
                  title="Remove from community"
                >✕</button>
              <% end %>
            </div>
          </div>
        <% end %>
        <div :if={@community_questions == []} class="text-sm" style="color:var(--text-muted)">
          No community questions yet.
        </div>
      </div>
    </div>

    <%!-- Floating tool windows + minimized dock, same machinery as the game
          and community pages. --%>
    <ToolPanel.tool_panel {assigns} />
    """
  end

  defp status_color("published"),
    do: "background:color-mix(in srgb,var(--green) 20%,var(--bg-surface));color:var(--green)"

  defp status_color("pending_review"),
    do: "background:color-mix(in srgb,var(--yellow) 20%,var(--bg-surface));color:var(--yellow)"

  defp status_color("rejected"),
    do: "background:color-mix(in srgb,var(--red) 20%,var(--bg-surface));color:var(--red)"

  defp status_color(_),
    do: "background:var(--bg-subtle);color:var(--text-secondary)"
end
