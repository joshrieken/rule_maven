defmodule RuleMavenWeb.GameLive.Faq do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, Faq}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, game: nil, faqs: [], search: "")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    game = Games.get_game!(id)
    faqs = Faq.list_published(game)

    {:noreply, assign(socket, game: game, faqs: faqs, search: "")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search: query)}
  end

  @impl true
  def render(assigns) do
    filtered =
      if assigns.search == "" do
        assigns.faqs
      else
        term = String.downcase(assigns.search)

        Enum.filter(assigns.faqs, fn f ->
          String.contains?(String.downcase(f.canonical_question), term) or
            String.contains?(String.downcase(f.canonical_answer), term)
        end)
      end

    assigns = assign(assigns, filtered: filtered)

    ~H"""
    <div style="margin:0;padding:0 1rem;max-width:48rem;margin:0 auto">
      <.link navigate={~p"/games/#{@game.id}"} style="color:var(--blue);font-size:0.75rem">&larr; Back to questions</.link>

      <h1 style="font-size:1.3rem;font-weight:700;margin:0.5rem 0 0.25rem">
        {@game.name} &mdash; Official FAQ
      </h1>
      <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 1rem">
        Curated answers to the best questions. Reviewed and approved by game masters.
      </p>

      <div style="margin-bottom:1rem">
        <input
          type="text"
          name="query"
          value={@search}
          placeholder="Search FAQ..."
          phx-change="search"
          style="width:100%;border:1px solid var(--border);border-radius:0.5rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
          autocomplete="off"
        />
      </div>

      <%= if @filtered == [] do %>
        <p style="color:var(--text-muted);font-size:0.85rem;text-align:center;padding:2rem 0">
          <%= if @faqs == [] do %>
            No FAQ entries yet. Popular questions will be promoted here automatically.
          <% else %>
            No FAQ entries match your search.
          <% end %>
        </p>
      <% else %>
        <div style="display:flex;flex-direction:column;gap:1rem">
          <%= for faq <- @filtered do %>
            <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem">
              <div style="font-weight:700;font-size:0.95rem;color:var(--text);margin-bottom:0.5rem">
                Q: {faq.canonical_question}
              </div>
              <div style="font-size:0.88rem;color:var(--text);line-height:1.5">
                {render_faq_answer(faq.canonical_answer)}
              </div>
              <%= if faq.auto_approved do %>
                <div style="margin-top:0.5rem;font-size:0.65rem;color:var(--text-muted)">
                  Auto-promoted &middot; {faq.auto_approve_reason}
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_faq_answer(text) do
    case MDEx.to_html(text || "") do
      {:ok, html} ->
        ~s(<div class="md-answer" style="line-height:1.5;margin:0">#{html}</div>)
        |> Phoenix.HTML.raw()

      {:error, _} ->
        text
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.raw()
    end
  end
end
