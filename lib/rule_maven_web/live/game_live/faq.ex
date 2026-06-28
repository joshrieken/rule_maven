defmodule RuleMavenWeb.GameLive.Faq do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game!(id)
    is_admin = RuleMaven.Users.can?(socket.assigns.current_user, :admin)
    categories = Games.list_game_categories(game)
    community_questions = Games.faq_questions(game)

    question_ids = Enum.map(community_questions, & &1.id)
    category_map = Games.categories_for_questions(question_ids)

    {:ok,
     assign(socket,
       game: game,
       is_admin: is_admin,
       categories: categories,
       community_questions: community_questions,
       category_map: category_map,
       filter_category: nil,
       page_title: "FAQ — #{game.name}"
     )}
  end

  @impl true
  def handle_params(%{"category" => cat_id}, _uri, socket) do
    case Integer.parse(cat_id) do
      {id, ""} -> {:noreply, assign(socket, filter_category: id)}
      _ -> {:noreply, assign(socket, filter_category: nil)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, filter_category: nil)}
  end

  @impl true
  def handle_event("filter_category", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {cat_id, ""} ->
        socket =
          if socket.assigns.filter_category == cat_id do
            assign(socket, filter_category: nil)
          else
            assign(socket, filter_category: cat_id)
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("promote", %{"id" => id_str}, socket) do
    if socket.assigns.is_admin do
      with {id, ""} <- Integer.parse(id_str) do
        Games.set_question_visibility(id, "community")
      end
    end

    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("reject", %{"id" => id_str}, socket) do
    if socket.assigns.is_admin do
      with {id, ""} <- Integer.parse(id_str) do
        Games.set_question_visibility(id, "private")
      end
    end

    {:noreply, reload(socket)}
  end

  defp reload(socket) do
    game = socket.assigns.game
    community_questions = Games.faq_questions(game)
    question_ids = Enum.map(community_questions, & &1.id)
    category_map = Games.categories_for_questions(question_ids)

    assign(socket, community_questions: community_questions, category_map: category_map)
  end

  defp questions_for_category(questions, category_map, cat_id) do
    Enum.filter(questions, fn q ->
      cats = Map.get(category_map, q.id, [])
      Enum.any?(cats, &(&1.id == cat_id))
    end)
  end

  defp untagged_questions(questions, category_map) do
    Enum.filter(questions, fn q ->
      Map.get(category_map, q.id, []) == []
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game.image_url} />
    <div style="max-width:52rem;margin:0 auto;padding:1.5rem 1rem;position:relative;z-index:1">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem">
        <.link navigate={~p"/games/#{@game.id}"} class="back-link" style="margin-bottom:0">
          &larr; Back to {@game.name}
        </.link>
        <.link
          :if={@is_admin}
          navigate={~p"/games/#{@game.id}/review"}
          class="back-link"
          style="margin-bottom:0"
        >
          Admin Review →
        </.link>
      </div>

      <h1 style="font-size:1.25rem;font-weight:700;margin-bottom:0.25rem">{@game.name} — FAQ</h1>
      <p style="font-size:0.75rem;color:var(--text-secondary);margin-bottom:1.25rem">
        Community-curated rules answers
      </p>

      <%!-- Category filter pills --%>
      <%= if @categories != [] do %>
        <div style="display:flex;flex-wrap:wrap;gap:0.35rem;margin-bottom:1.25rem">
          <%= for cat <- @categories do %>
            <button
              type="button"
              phx-click="filter_category"
              phx-value-id={cat.id}
              style={"font-size:0.65rem;padding:0.2rem 0.55rem;border-radius:1rem;border:1px solid #{if @filter_category == cat.id, do: "var(--accent)", else: "var(--border)"};background:#{if @filter_category == cat.id, do: "var(--accent)", else: "var(--bg-subtle)"};color:#{if @filter_category == cat.id, do: "var(--accent-text,#fff)", else: "var(--text-secondary)"};cursor:pointer"}
            >
              {cat.name}
            </button>
          <% end %>
          <button
            :if={@filter_category != nil}
            type="button"
            phx-click="filter_category"
            phx-value-id={@filter_category}
            style="font-size:0.65rem;padding:0.2rem 0.55rem;border-radius:1rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-muted);cursor:pointer"
          >
            Clear ✕
          </button>
        </div>
      <% end %>

      <%= if @community_questions == [] do %>
        <p style="font-size:0.8rem;color:var(--text-muted)">No community answers yet for this game.</p>
      <% else %>
        <%= if @filter_category do %>
          <%!-- Filtered view: single category --%>
          <% filtered = questions_for_category(@community_questions, @category_map, @filter_category) %>
          <% current_cat = Enum.find(@categories, &(&1.id == @filter_category)) %>
          <%= if current_cat do %>
            <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.6rem">
              {current_cat.name}
            </h2>
            <p :if={current_cat.description} style="font-size:0.72rem;color:var(--text-muted);margin-bottom:0.75rem">
              {current_cat.description}
            </p>
          <% end %>
          <div style="display:flex;flex-direction:column;gap:0.6rem">
            <%= for q <- filtered do %>
              <.question_card q={q} is_admin={@is_admin} game={@game} />
            <% end %>
            <p :if={filtered == []} style="font-size:0.75rem;color:var(--text-muted)">No questions in this category yet.</p>
          </div>
        <% else %>
          <%!-- All categories view --%>
          <%= for cat <- @categories do %>
            <% cat_qs = questions_for_category(@community_questions, @category_map, cat.id) %>
            <%= if cat_qs != [] do %>
              <div id={"category-#{cat.id}"} style="margin-bottom:1.75rem">
                <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.5rem;display:flex;align-items:center;gap:0.4rem">
                  {cat.name}
                  <span style="font-size:0.65rem;font-weight:400;color:var(--text-muted)">({length(cat_qs)})</span>
                </h2>
                <div style="display:flex;flex-direction:column;gap:0.6rem">
                  <%= for q <- cat_qs do %>
                    <.question_card q={q} is_admin={@is_admin} game={@game} />
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
          <%!-- Untagged --%>
          <% untagged = untagged_questions(@community_questions, @category_map) %>
          <%= if untagged != [] do %>
            <div id="category-general" style="margin-bottom:1.75rem">
              <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.5rem">
                General
              </h2>
              <div style="display:flex;flex-direction:column;gap:0.6rem">
                <%= for q <- untagged do %>
                  <.question_card q={q} is_admin={@is_admin} game={@game} />
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp question_card(assigns) do
    ~H"""
    <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.45rem;background:var(--bg-surface)">
      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.75rem">
        <div style="flex:1;min-width:0">
          <.link
            navigate={~p"/games/#{@game.id}?t=#{@q.id}"}
            style="font-size:0.82rem;font-weight:600;color:var(--text);text-decoration:none;word-break:break-word;display:block;margin-bottom:0.35rem"
          >
            {@q.canonical_question || @q.question}
          </.link>
          <div style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;word-break:break-word">
            {String.slice(@q.canonical_answer || @q.answer || "", 0, 220)}
            <%= if String.length(@q.canonical_answer || @q.answer || "") > 220 do %>
              <span style="color:var(--text-muted)">…</span>
            <% end %>
          </div>
          <span :if={@q.canonical_question} style="font-size:0.6rem;color:var(--accent);margin-top:0.2rem;display:block">★ curated</span>
        </div>
        <%= if @is_admin do %>
          <button
            phx-click="reject"
            phx-value-id={@q.id}
            style="color:var(--text-muted);background:var(--bg-subtle);border:1px solid var(--border);font-size:0.65rem;cursor:pointer;padding:0.1rem 0.35rem;border-radius:0.25rem;flex-shrink:0"
            title="Remove from community"
          >✕</button>
        <% end %>
      </div>
    </div>
    """
  end
end
