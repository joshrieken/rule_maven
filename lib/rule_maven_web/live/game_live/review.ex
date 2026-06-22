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
         candidates: Faq.list_pending_candidates(game),
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
  def handle_event("approve_candidate", %{"id" => id_str}, socket) do
    candidate = Faq.get_candidate!(String.to_integer(id_str))

    case Faq.approve_candidate(candidate) do
      {:ok, _faq_entry} ->
        candidates = Faq.list_pending_candidates(socket.assigns.game)
        faqs = Faq.list_faqs(socket.assigns.game)

        {:noreply,
         socket
         |> assign(candidates: candidates, faqs: faqs)
         |> put_flash(:info, "FAQ candidate approved and published.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to approve FAQ candidate.")}
    end
  end

  @impl true
  def handle_event("reject_candidate", %{"id" => id_str}, socket) do
    candidate = Faq.get_candidate!(String.to_integer(id_str))
    Faq.reject_candidate(candidate)

    candidates = Faq.list_pending_candidates(socket.assigns.game)
    {:noreply, assign(socket, candidates: candidates)}
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
                  style="background:var(--red);color:white;border:none;padding:0.2rem 0.5rem;border-radius:0.25rem;font-size:0.75rem;cursor:pointer"
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

      <!-- FAQ Candidates (Review Queue) -->
      <h2 class="text-lg font-semibold mt-6 mb-3">
        FAQ Candidates
        <span style="font-size:0.75rem;color:var(--text-muted);font-weight:400">(pending review)</span>
      </h2>
      <div style="display:flex;flex-direction:column;gap:0.75rem">
        <%= for candidate <- @candidates do %>
          <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-surface)">
            <div style="margin-bottom:0.5rem">
              <span class="font-semibold text-sm">Q: {candidate.question_text}</span>
            </div>
            <%= if candidate.sample_answer_text do %>
              <div style="font-size:0.8rem;color:var(--text-muted);margin-bottom:0.3rem">
                A: {String.slice(candidate.sample_answer_text, 0, 200)}
              </div>
            <% end %>
            <%= if candidate.sample_citation do %>
              <div style="font-size:0.75rem;color:var(--text);font-style:italic;margin-bottom:0.3rem">
                "{String.slice(candidate.sample_citation, 0, 150)}"
              </div>
            <% end %>
            <div class="flex items-center justify-between" style="margin-top:0.5rem">
              <div style="font-size:0.7rem;color:var(--text-muted)">
                <span style="color:var(--red)">👎 {candidate.thumbs_down_count}</span>
                <span style="margin-left:0.5rem">asked {candidate.total_asked_count}x</span>
              </div>
              <div class="flex gap-1" style="flex-shrink:0">
                <button
                  phx-click="approve_candidate"
                  phx-value-id={candidate.id}
                  style="background:var(--accent);color:white;border:none;padding:0.2rem 0.5rem;border-radius:0.25rem;font-size:0.75rem;cursor:pointer"
                >
                  Approve
                </button>
                <button
                  phx-click="reject_candidate"
                  phx-value-id={candidate.id}
                  style="background:var(--red);color:white;border:none;padding:0.2rem 0.5rem;border-radius:0.25rem;font-size:0.75rem;cursor:pointer"
                >
                  Reject
                </button>
              </div>
            </div>
          </div>
        <% end %>
        <div :if={@candidates == []} class="text-sm" style="color:var(--text-muted)">
          No FAQ candidates pending review. They will appear as questions receive thumbs-down feedback.
        </div>
      </div>
    </div>
    """
  end

  defp status_color("published"),
    do: "background: color-mix(in srgb, var(--green) 20%, var(--bg-surface)); color: var(--green)"

  defp status_color("pending_review"),
    do:
      "background: color-mix(in srgb, var(--yellow) 20%, var(--bg-surface)); color: var(--yellow)"

  defp status_color("draft"),
    do: "background: color-mix(in srgb, var(--blue) 20%, var(--bg-surface)); color: var(--blue)"

  defp status_color("discarded"), do: "background: var(--bg-subtle); color: var(--text-secondary)"
  defp status_color(_), do: "background: var(--bg-subtle); color: var(--text-secondary)"
end
