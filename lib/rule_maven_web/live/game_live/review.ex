defmodule RuleMavenWeb.GameLive.Review do
  use RuleMavenWeb, :live_view

  alias RuleMaven.CheatSheet
  alias RuleMaven.Faq
  alias RuleMaven.Games

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game!(id)

    if RuleMaven.Users.game_master?(socket.assigns.current_user) do
      {:ok,
       assign(socket,
         game: game,
         documents: Games.list_documents(game),
         faqs: Faq.list_faqs(game),
         page_title: "Review — #{game.name}"
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/games/#{game.id}")}
    end
  end

  @impl true
  def handle_event("approve_doc", %{"id" => id_str}, socket) do
    doc = Games.get_document!(String.to_integer(id_str))
    Games.update_document(doc, %{status: "published"})

    docs = Games.list_documents(socket.assigns.game)
    {:noreply, assign(socket, documents: docs)}
  end

  @impl true
  def handle_event("approve_faq", %{"id" => id_str}, socket) do
    faq = Faq.get_faq!(String.to_integer(id_str))
    Faq.approve_faq(faq, socket.assigns.current_user.id)

    faqs = Faq.list_faqs(socket.assigns.game)
    {:noreply, assign(socket, faqs: faqs)}
  end

  @impl true
  def handle_event("discard_faq", %{"id" => id_str}, socket) do
    faq = Faq.get_faq!(String.to_integer(id_str))
    Faq.discard_faq(faq)

    faqs = Faq.list_faqs(socket.assigns.game)
    {:noreply, assign(socket, faqs: faqs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:48rem;margin:0 auto;padding:1.5rem 1rem">
      <.link navigate={~p"/games/#{@game.id}"} class="text-blue-600 hover:underline text-sm">
        &larr; Back to {String.slice(@game.name, 0, 20)}
      </.link>

      <h1 class="text-xl font-bold mt-4 mb-6">Review — {@game.name}</h1>

      <!-- Documents -->
      <h2 class="text-lg font-semibold mt-6 mb-3">Documents</h2>
      <div style="display:flex;flex-direction:column;gap:0.75rem">
        <%= for doc <- @documents do %>
          <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-surface)">
            <div class="flex items-center justify-between">
              <div>
                <span class="font-semibold">{doc.label}</span>
                <span style={"margin-left:0.5rem;font-size:0.75rem;padding:0.15rem 0.4rem;border-radius:0.25rem;#{status_color(doc.status)}"}>
                  {doc.status}
                </span>
                <span class="text-xs" style="color:var(--text-muted);margin-left:0.5rem">
                  v{doc.version}
                </span>
              </div>
              <button
                :if={doc.status != "published"}
                phx-click="approve_doc"
                phx-value-id={doc.id}
                style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.25rem;font-size:0.8rem;cursor:pointer"
              >
                Approve
              </button>
            </div>
            <%= if CheatSheet.active_version(doc.id) do %>
              <div class="text-xs mt-1" style="color:var(--text-muted)">
                Cheatsheet: ready
              </div>
            <% end %>
          </div>
        <% end %>
        <div :if={@documents == []} class="text-sm" style="color:var(--text-muted)">
          No documents yet.
        </div>
      </div>

      <!-- FAQ Entries -->
      <h2 class="text-lg font-semibold mt-8 mb-3">FAQ Entries</h2>
      <div style="display:flex;flex-direction:column;gap:0.75rem">
        <%= for faq <- @faqs do %>
          <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-surface)">
            <div class="flex items-start justify-between gap-4">
              <div class="flex-1" style="min-width:0">
                <div class="font-semibold text-sm" style="word-break:break-word">
                  {faq.canonical_question}
                </div>
                <div
                  class="text-xs mt-1"
                  style="color:var(--text-muted);line-height:1.4;word-break:break-word"
                >
                  {String.slice(faq.canonical_answer, 0, 120)}...
                </div>
                <div class="flex items-center gap-2 mt-1">
                  <span style={"font-size:0.7rem;padding:0.1rem 0.3rem;border-radius:0.25rem;#{status_color(faq.status)}"}>
                    {faq.status}
                  </span>
                  <%= if faq.auto_approved do %>
                    <span class="text-xs" style="color:var(--text-muted)">auto</span>
                  <% end %>
                </div>
              </div>
              <div class="flex gap-1" style="flex-shrink:0">
                <button
                  :if={faq.status == "draft"}
                  phx-click="approve_faq"
                  phx-value-id={faq.id}
                  style="background:var(--accent);color:white;border:none;padding:0.2rem 0.5rem;border-radius:0.25rem;font-size:0.75rem;cursor:pointer"
                >
                  Approve
                </button>
                <button
                  :if={faq.status == "draft"}
                  phx-click="discard_faq"
                  phx-value-id={faq.id}
                  style="background:#ef4444;color:white;border:none;padding:0.2rem 0.5rem;border-radius:0.25rem;font-size:0.75rem;cursor:pointer"
                >
                  Discard
                </button>
              </div>
            </div>
          </div>
        <% end %>
        <div :if={@faqs == []} class="text-sm" style="color:var(--text-muted)">
          No FAQ entries yet. They will appear as questions are asked and clustered.
        </div>
      </div>
    </div>
    """
  end

  defp status_color("published"), do: "background:#dcfce7;color:#166534"
  defp status_color("pending_review"), do: "background:#fef3c7;color:#92400e"
  defp status_color("draft"), do: "background:#dbeafe;color:#1e40af"
  defp status_color("discarded"), do: "background:#f3f4f6;color:#6b7280"
  defp status_color(_), do: "background:#f3f4f6;color:#6b7280"
end
