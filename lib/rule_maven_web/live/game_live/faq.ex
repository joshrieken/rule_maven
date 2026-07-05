defmodule RuleMavenWeb.GameLive.Faq do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game_by_token(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      game ->
        mount_game(game, socket)
    end
  end

  defp mount_game(game, socket) do
    is_admin = RuleMaven.Users.can?(socket.assigns.current_user, :admin)
    categories = Games.list_game_categories(game)
    user_id = socket.assigns.current_user.id

    community_questions = Games.faq_questions(game)
    question_ids = Enum.map(community_questions, & &1.id)
    favorited_ids = Games.favorited_answer_ids(user_id, question_ids)
    community_questions = sort_favorited_first(community_questions, favorited_ids)
    category_map = Games.categories_for_questions(question_ids)
    flagged_ids = Games.user_flagged_ids(user_id)

    {:ok,
     assign(socket,
       game: game,
       is_admin: is_admin,
       categories: categories,
       community_questions: community_questions,
       favorited_ids: favorited_ids,
       category_map: category_map,
       flagged_ids: flagged_ids,
       filter_category: nil,
       page_title: "FAQ — #{game.name}"
     )}
  end

  @impl true
  def handle_params(%{"category" => cat_id}, _uri, socket) do
    case RuleMaven.Hashid.decode(cat_id) do
      {:ok, id} -> {:noreply, assign(socket, filter_category: id)}
      :error -> {:noreply, assign(socket, filter_category: nil)}
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

  @impl true
  def handle_event("favorite_community_answer", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str),
         {:ok, _favorited?} <-
           Games.toggle_answer_favorite(socket.assigns.current_user.id, id) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("report_answer", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user = socket.assigns.current_user

    # Scope to this game so a forged id from another game can't be flagged here.
    if Enum.any?(socket.assigns.community_questions, &(&1.id == id)) do
      case Games.report_answer(id, user) do
        {:ok, %{pulled: pulled}} ->
          socket =
            socket
            |> assign(flagged_ids: MapSet.put(socket.assigns.flagged_ids, id))
            |> put_flash(:info, report_flash(pulled))

          {:noreply, reload(socket)}

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp report_flash(true), do: "Reported and pulled from the FAQ for review. Thanks!"
  defp report_flash(false), do: "Reported — thanks. A moderator will take a look."

  defp reload(socket) do
    game = socket.assigns.game
    user_id = socket.assigns.current_user.id

    community_questions = Games.faq_questions(game)
    question_ids = Enum.map(community_questions, & &1.id)
    favorited_ids = Games.favorited_answer_ids(user_id, question_ids)
    community_questions = sort_favorited_first(community_questions, favorited_ids)
    category_map = Games.categories_for_questions(question_ids)

    assign(socket,
      community_questions: community_questions,
      favorited_ids: favorited_ids,
      category_map: category_map
    )
  end

  # Favorited questions float to the top within whatever list they're
  # rendered in (a category bucket, the untagged group, …); Enum.sort_by is
  # stable, so ties keep their original (faq_questions-ranked) order.
  defp sort_favorited_first(questions, favorited_ids) do
    Enum.sort_by(questions, fn q -> if MapSet.member?(favorited_ids, q.id), do: 0, else: 1 end)
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
        <.link navigate={~p"/games/#{@game}"} class="back-link" style="margin-bottom:0">
          &larr; Back to {@game.name}
        </.link>
        <.link
          :if={@is_admin}
          navigate={~p"/games/#{@game}/review"}
          class="back-link"
          style="margin-bottom:0"
        >
          Admin Review →
        </.link>
      </div>

      <h1 style="font-size:1.25rem;font-weight:700;margin-bottom:0.25rem">{@game.name} — FAQ</h1>
      <p style="font-size:0.75rem;color:var(--text-secondary);margin-bottom:1rem">
        The questions players ask most, with answers drawn from the rulebook.
      </p>

      <div
        :if={@community_questions != []}
        style="display:flex;align-items:center;gap:0.6rem;padding:0.6rem 0.75rem;margin-bottom:1.25rem;background:var(--bg-surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:0.4rem"
      >
        <span style="font-size:1.1rem;line-height:1">📖</span>
        <p style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;margin:0">
          These answers are <strong>drawn from the official rules</strong>
          and surfaced by admins or the community as the most helpful. Always double-check the rulebook for anything that matters.
        </p>
      </div>

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
        <p style="font-size:0.8rem;color:var(--text-muted)">
          No community answers yet for this game.
        </p>
      <% else %>
        <%= if @filter_category do %>
          <%!-- Filtered view: single category --%>
          <% filtered = questions_for_category(@community_questions, @category_map, @filter_category) %>
          <% current_cat = Enum.find(@categories, &(&1.id == @filter_category)) %>
          <%= if current_cat do %>
            <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.6rem">
              {current_cat.name}
            </h2>
            <p
              :if={current_cat.description}
              style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;margin-bottom:0.9rem;padding:0.6rem 0.75rem;background:var(--bg-surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:0.4rem"
            >
              {current_cat.description}
            </p>
          <% end %>
          <div style="display:flex;flex-direction:column;gap:0.6rem">
            <%= for q <- filtered do %>
              <.question_card
                q={q}
                is_admin={@is_admin}
                game={@game}
                favorited_ids={@favorited_ids}
                flagged_ids={@flagged_ids}
              />
            <% end %>
            <p :if={filtered == []} style="font-size:0.75rem;color:var(--text-muted)">
              No questions in this category yet.
            </p>
          </div>
        <% else %>
          <%!-- All categories view --%>
          <%= for cat <- @categories do %>
            <% cat_qs = questions_for_category(@community_questions, @category_map, cat.id) %>
            <%= if cat_qs != [] do %>
              <div id={"category-#{cat.id}"} style="margin-bottom:1.75rem">
                <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.5rem;display:flex;align-items:center;gap:0.4rem">
                  {cat.name}
                  <span style="font-size:0.65rem;font-weight:400;color:var(--text-muted)">({length(
                    cat_qs
                  )})</span>
                </h2>
                <div style="display:flex;flex-direction:column;gap:0.6rem">
                  <%= for q <- cat_qs do %>
                    <.question_card
                      q={q}
                      is_admin={@is_admin}
                      game={@game}
                      favorited_ids={@favorited_ids}
                      flagged_ids={@flagged_ids}
                    />
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
                  <.question_card
                    q={q}
                    is_admin={@is_admin}
                    game={@game}
                    favorited_ids={@favorited_ids}
                    flagged_ids={@flagged_ids}
                  />
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Flatten markdown to plain text for the card preview. The preview is a short
  # slice, so rendering real markdown (and slicing the HTML) would emit broken
  # tags — strip the syntax to readable text instead.
  defp strip_markdown(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/__(.+?)__/, "\\1")
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/_(.+?)_/, "\\1")
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/^>\s?/m, "")
    |> String.replace(~r/^[-*+]\s+/m, "")
    |> String.replace(~r/^\d+\.\s+/m, "")
    |> String.replace(~r/\s*\n\s*\n\s*/, " ")
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.trim()
  end

  defp question_card(assigns) do
    ~H"""
    <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.45rem;background:var(--bg-surface)">
      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.75rem">
        <div style="flex:1;min-width:0">
          <.link
            navigate={~p"/games/#{@game}?t=#{RuleMaven.Hashid.encode(@q.id)}"}
            style="font-size:0.82rem;font-weight:600;color:var(--text);text-decoration:none;word-break:break-word;display:block;margin-bottom:0.35rem"
          >
            {QuestionLog.display_question(@q)}
          </.link>
          <% preview = strip_markdown(@q.canonical_answer || @q.answer || "") %>
          <div style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;word-break:break-word">
            {String.slice(preview, 0, 220)}
            <%= if String.length(preview) > 220 do %>
              <span style="color:var(--text-muted)">…</span>
            <% end %>
          </div>
          <div style="display:flex;flex-wrap:wrap;gap:0.3rem;margin-top:0.4rem">
            <span
              :if={@q.verified}
              style="font-size:0.6rem;font-weight:600;color:var(--green);background:color-mix(in srgb, var(--green) 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              ✅ Admin-verified
            </span>
            <span
              :if={@q.canonical_question}
              style="font-size:0.6rem;font-weight:600;color:var(--accent);background:color-mix(in srgb, var(--accent) 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              ★ Curated
            </span>
            <span
              :if={@q.cited_page}
              style="font-size:0.6rem;font-weight:600;color:var(--text-secondary);background:var(--bg-subtle);padding:0.1rem 0.4rem;border-radius:1rem"
            >
              📖 Rulebook p.{@q.cited_page}
            </span>
            <span
              :if={!@q.cited_page && @q.citation_valid}
              style="font-size:0.6rem;font-weight:600;color:var(--text-secondary);background:var(--bg-subtle);padding:0.1rem 0.4rem;border-radius:1rem"
            >
              📖 Cited from rulebook
            </span>
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:0.3rem;flex-shrink:0">
          <% fav? = MapSet.member?(@favorited_ids, @q.id) %>
          <button
            type="button"
            phx-click="favorite_community_answer"
            phx-value-id={@q.id}
            style={"background:none;border:none;padding:0;line-height:1;font-size:0.95rem;cursor:pointer;#{if fav?, do: "color:#e05c2a", else: "color:var(--text-muted)"}"}
            title={if fav?, do: "Remove from your favorites", else: "Favorite — moves to top of this list"}
          >{if fav?, do: "♥", else: "♡"}</button>

          <!-- Overflow: secondary actions (copy, regenerate, report) -->
          <details class="card-menu">
            <summary class="card-menu__trigger" title="More actions">⋯</summary>
            <div class="card-menu__pop card-menu__pop--right">
              <button
                type="button"
                id={"faq-copy-#{@q.id}"}
                phx-hook="ClipboardCopy"
                data-clipboard-text={"Q: #{QuestionLog.display_question(@q)}\n\nA: #{strip_markdown(@q.canonical_answer || @q.answer || "")}"}
                class="card-menu__item"
                title="Copy question and answer"
              >📋 Copy Q&amp;A</button>
              <.link
                navigate={~p"/games/#{@game}?t=#{RuleMaven.Hashid.encode(@q.id)}"}
                class="card-menu__item"
                title="Open this answer in the chat to generate a fresh version"
              >↻ Regenerate</.link>
              <%= if MapSet.member?(@flagged_ids, @q.id) do %>
                <button
                  type="button"
                  disabled
                  class="card-menu__item"
                  style="opacity:0.6;cursor:default"
                  title="You reported this answer"
                >✓ Reported</button>
              <% else %>
                <button
                  type="button"
                  phx-click="report_answer"
                  phx-value-id={@q.id}
                  data-confirm="Report this answer as wrong or unhelpful? A moderator will review it."
                  class="card-menu__item"
                  title="Report a wrong or unhelpful answer"
                >🚩 Report</button>
              <% end %>
            </div>
          </details>

          <%= if @is_admin do %>
            <button
              phx-click="reject"
              phx-value-id={@q.id}
              style="color:var(--text-muted);background:var(--bg-subtle);border:1px solid var(--border);font-size:0.65rem;cursor:pointer;padding:0.1rem 0.35rem;border-radius:0.25rem"
              title="Remove from community"
            >✕</button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
