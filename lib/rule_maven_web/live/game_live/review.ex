defmodule RuleMavenWeb.GameLive.Review do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game!(id)
    is_admin = RuleMaven.Users.game_master?(socket.assigns.current_user)

    if !is_admin do
      {:ok, push_navigate(socket, to: ~p"/games/#{id}/faq")}
    else
      {:ok,
       assign(socket,
         game: game,
         is_admin: is_admin,
         documents: Games.list_documents(game),
         community_questions: Games.faq_questions(game, 100),
         categories: Games.list_game_categories(game),
         page_title: "Review — #{game.name}"
       )}
    end
  end

  @impl true
  def handle_event("approve_doc", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      doc = Games.get_document!(id)
      Games.update_document(doc, %{status: "published"})
    end

    {:noreply, assign(socket, documents: Games.list_documents(socket.assigns.game))}
  end

  @impl true
  def handle_event("promote", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      Games.set_question_visibility(id, "community")
    end

    {:noreply, assign(socket, community_questions: Games.faq_questions(socket.assigns.game, 100))}
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
    <div style="max-width:48rem;margin:0 auto;padding:1.5rem 1rem">
      <.link
        navigate={~p"/games/#{@game.id}"}
        style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem"
      >
        &larr; Back to {String.slice(@game.name, 0, 20)}
      </.link>

      <h1 class="text-xl font-bold mt-4 mb-6">Review — {@game.name}</h1>

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
                <button
                  :if={doc.status != "published"}
                  phx-click="approve_doc"
                  phx-value-id={doc.id}
                  style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.25rem;font-size:0.8rem;cursor:pointer"
                >Approve</button>
              </div>
            </div>
          <% end %>
          <div :if={@documents == []} class="text-sm" style="color:var(--text-muted)">No documents yet.</div>
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
                  {q.canonical_question || q.question}
                </div>
                <div class="text-xs mt-1" style="color:var(--text-muted);line-height:1.4;word-break:break-word">
                  {String.slice(q.canonical_answer || q.answer || "", 0, 180)}
                </div>
                <%= if q.canonical_question do %>
                  <span style="font-size:0.65rem;color:var(--accent);margin-top:0.25rem;display:block">★ curated</span>
                <% end %>
              </div>
              <%= if @is_admin do %>
                <button
                  phx-click="reject"
                  phx-value-id={q.id}
                  style="color:var(--text-muted);background:var(--bg-subtle);border:1px solid var(--border);font-size:0.7rem;cursor:pointer;padding:0.15rem 0.4rem;border-radius:0.3rem;flex-shrink:0"
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
    """
  end

  defp status_color("published"),
    do: "background:color-mix(in srgb,var(--green) 20%,var(--bg-surface));color:var(--green)"
  defp status_color("pending_review"),
    do: "background:color-mix(in srgb,var(--yellow) 20%,var(--bg-surface));color:var(--yellow)"
  defp status_color(_),
    do: "background:var(--bg-subtle);color:var(--text-secondary)"
end
