defmodule RuleMavenWeb.AdminLive.Questions do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Games, Groups, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      questions = Games.admin_list_questions()

      {:ok,
       assign(socket,
         page_title: "Questions",
         questions: questions,
         filter_game_id: nil,
         filter_game_name: nil,
         game_query: "",
         game_results: [],
         filter_user_id: nil,
         filter_username: nil,
         user_query: "",
         user_results: [],
         filter_group_id: nil,
         filter_group_name: nil,
         group_search_query: "",
         group_search_results: [],
         filter_status: nil,
         search: "",
         confirm_delete_id: nil,
         expanded_id: nil,
         audit: nil,
         editing_canonical_id: nil,
         canon_q: "",
         canon_a: ""
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["status"] do
        s
        when s in ["needs_review", "answered", "pending", "refused", "error", "publish_pending", "pooled"] ->
          socket |> assign(filter_status: s) |> reload()

        _ ->
          socket
      end

    socket =
      with id_str when is_binary(id_str) <- params["user_id"],
           {id, _} <- Integer.parse(id_str),
           %{} = user <- Users.get_user(id) do
        socket
        |> assign(filter_user_id: user.id, filter_username: user.username)
        |> reload()
      else
        _ -> socket
      end

    case params["focus"] && Integer.parse(params["focus"]) do
      {id, _} -> {:noreply, assign(socket, expanded_id: id)}
      _ -> {:noreply, socket}
    end
  end

  defp reload(socket) do
    questions =
      Games.admin_list_questions(
        game_id: socket.assigns.filter_game_id,
        user_id: socket.assigns.filter_user_id,
        group_id: socket.assigns.filter_group_id,
        status: socket.assigns.filter_status,
        search: socket.assigns.search
      )

    assign(socket, questions: questions, confirm_delete_id: nil)
  end

  @impl true
  def handle_event("open_audit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, audit: RuleMavenWeb.AuditModal.fetch(id, socket.assigns.current_user))}

  def handle_event("close_audit", _params, socket),
    do: {:noreply, assign(socket, audit: nil)}

  def handle_event("filter_status", params, socket) do
    status = if params["status"] == "", do: nil, else: params["status"]
    {:noreply, socket |> assign(filter_status: status) |> reload()}
  end

  # Game filter typeahead. Avoids loading the entire ~150k catalog into a
  # <select>; matches are searched on demand, mirroring the game-form picker.
  def handle_event("search_game", %{"value" => query}, socket) do
    query = query |> String.trim() |> String.slice(0, 200)
    results = if query == "", do: [], else: Games.search_catalog(query, limit: 15)
    {:noreply, assign(socket, game_query: query, game_results: results)}
  end

  def handle_event("select_game", %{"id" => id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(
       filter_game_id: String.to_integer(id),
       filter_game_name: name,
       game_query: "",
       game_results: []
     )
     |> reload()}
  end

  def handle_event("clear_game_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(filter_game_id: nil, filter_game_name: nil, game_query: "", game_results: [])
     |> reload()}
  end

  # User (asker) filter typeahead, same pattern as the game filter above.
  def handle_event("search_user", %{"value" => query}, socket) do
    query = query |> String.trim() |> String.slice(0, 200)
    results = if query == "", do: [], else: Users.search_users(query, limit: 15)
    {:noreply, assign(socket, user_query: query, user_results: results)}
  end

  def handle_event("select_user", %{"id" => id, "username" => username}, socket) do
    {:noreply,
     socket
     |> assign(
       filter_user_id: String.to_integer(id),
       filter_username: username,
       user_query: "",
       user_results: []
     )
     |> reload()}
  end

  def handle_event("clear_user_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(filter_user_id: nil, filter_username: nil, user_query: "", user_results: [])
     |> reload()}
  end

  # Group (crew) filter typeahead, same pattern as game/user above.
  def handle_event("search_group", %{"value" => query}, socket) do
    query = query |> String.trim() |> String.slice(0, 200)
    results = if query == "", do: [], else: Groups.search_groups(query, limit: 15)
    {:noreply, assign(socket, group_search_query: query, group_search_results: results)}
  end

  def handle_event("select_group", %{"id" => id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(
       filter_group_id: String.to_integer(id),
       filter_group_name: name,
       group_search_query: "",
       group_search_results: []
     )
     |> reload()}
  end

  def handle_event("clear_group_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(
       filter_group_id: nil,
       filter_group_name: nil,
       group_search_query: "",
       group_search_results: []
     )
     |> reload()}
  end

  def handle_event("search", %{"search" => q}, socket) do
    {:noreply, socket |> assign(search: String.slice(q, 0, 200)) |> reload()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(search: "") |> reload()}
  end

  def handle_event("expand", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = if socket.assigns.expanded_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_id: expanded)}
  end

  def handle_event("delete_question", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: String.to_integer(id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.delete_question(q, socket.assigns.current_user, %{
               game_id: q.game_id,
               author_id: q.user_id
             }) do
          {:ok, _} ->
            {:noreply, reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete that question.")}
        end
    end
  end

  def handle_event("set_visibility", %{"id" => id, "visibility" => vis}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.update_question_visibility(q, vis) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "question.set_visibility",
              target_type: "question",
              target_id: q.id,
              target_label: admin_question_text(q),
              metadata: %{from: if(q.promoted, do: "community", else: "private"), to: vis}
            )

            {:noreply, reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't change visibility.")}
        end
    end
  end

  def handle_event("clear_flag", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.clear_needs_review(q) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "question.reapprove",
              target_type: "question",
              target_id: q.id,
              target_label: admin_question_text(q)
            )

            {:noreply, reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't re-approve that answer.")}
        end
    end
  end

  def handle_event("force_publish", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.force_publish_question(q) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "question.force_publish",
              target_type: "question",
              target_id: q.id,
              target_label: admin_question_text(q)
            )

            {:noreply, reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't force-publish that row.")}
        end
    end
  end

  # ── Canonical (curated FAQ text) editing ──

  def handle_event("edit_canonical", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        # Admins already see the raw question/answer in this list (see
        # `admin_question_text/1` / `admin_answer_text/1`), so prefill the curator
        # textarea with the same raw text rather than the public-facing withheld
        # placeholder.
        {:noreply,
         assign(socket,
           editing_canonical_id: id,
           canon_q: admin_question_text(q),
           canon_a: admin_answer_text(q)
         )}
    end
  end

  def handle_event("cancel_canonical", _params, socket) do
    {:noreply, assign(socket, editing_canonical_id: nil, canon_q: "", canon_a: "")}
  end

  def handle_event("canonical_change", params, socket) do
    {:noreply,
     assign(socket,
       canon_q: params["canon_q"] || socket.assigns.canon_q,
       canon_a: params["canon_a"] || socket.assigns.canon_a
     )}
  end

  def handle_event("save_canonical", _params, socket) do
    id = socket.assigns.editing_canonical_id

    case id && Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, editing_canonical_id: nil)}

      q ->
        case Games.update_canonical(q, socket.assigns.canon_q, socket.assigns.canon_a) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "question.set_canonical",
              target_type: "question",
              target_id: q.id,
              target_label: socket.assigns.canon_q
            )

            {:noreply,
             socket
             |> assign(editing_canonical_id: nil, canon_q: "", canon_a: "")
             |> put_flash(:info, "Saved curated FAQ text.")
             |> reload()}

          {:error, :canonical_question_conflicts_answer} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "That canonical question flips the meaning of the stored answer — regenerate the answer instead of relabelling it."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't save the curated text.")}
        end
    end
  end

  # `QuestionLog.listed_question/1` and `listed_answer/1` withhold crew/unscrubbed
  # text from other *users* (see `RuleMaven.Games.QuestionLog`). This LiveView is
  # already gated to `:admin`/`:superadmin` at mount, so admins reviewing the
  # Questions list should always see the real content, not "(withheld)".
  defp admin_question_text(q), do: q.canonical_question || q.question
  defp admin_answer_text(q), do: q.canonical_answer || q.answer

  defp status_of(q) do
    cond do
      q.answer == "Thinking..." -> :pending
      q.refused -> :refused
      is_binary(q.answer) && String.starts_with?(q.answer, "⚠️") -> :error
      true -> :answered
    end
  end

  defp status_label(:pending),
    do:
      {"Pending",
       "color:var(--accent-ink, var(--accent));background:color-mix(in srgb,var(--accent) 12%,transparent)"}

  defp status_label(:refused),
    do: {"Refused", "color:var(--text-muted);background:var(--bg-subtle)"}

  defp status_label(:error),
    do: {"Error", "color:var(--red);background:color-mix(in srgb,var(--red) 10%,transparent)"}

  defp status_label(:answered),
    do:
      {"Answered",
       "color:var(--green);background:color-mix(in srgb,var(--green) 10%,transparent)"}

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:72rem;margin:0 auto;padding:1.25rem 1.5rem">
      <RuleMavenWeb.AuditModal.audit_modal :if={@audit} audit={@audit} />
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;margin:0.25rem 0 1rem">
        <h1 style="font-size:1.5rem;font-weight:700">Questions ({length(@questions)})</h1>
      </div>

      <!-- Filters -->
      <div style="display:flex;gap:0.5rem;flex-wrap:wrap;margin-bottom:0.75rem;align-items:flex-start">
        <!-- Game filter typeahead -->
        <div style="position:relative;min-width:16rem">
          <%= if @filter_game_id do %>
            <div style="display:flex;align-items:center;gap:0.4rem;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg)">
              <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                Game: <strong>{@filter_game_name}</strong>
              </span>
              <button
                type="button"
                phx-click="clear_game_filter"
                class="btn-icon btn-xs"
              >✕</button>
            </div>
          <% else %>
            <input
              type="text"
              name="game_query"
              value={@game_query}
              autocomplete="off"
              phx-keyup="search_game"
              phx-debounce="250"
              placeholder="Filter by game…"
              style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
            />
            <%= if @game_results != [] do %>
              <div style="position:absolute;z-index:10;left:0;right:0;border:1px solid var(--border);border-radius:0.375rem;margin-top:0.15rem;background:var(--bg);max-height:14rem;overflow:auto;box-shadow:0 4px 12px rgba(0,0,0,0.15)">
                <%= for g <- @game_results do %>
                  <button
                    type="button"
                    phx-click="select_game"
                    phx-value-id={g.id}
                    phx-value-name={g.name}
                    class="block w-full text-left"
                    style="padding:0.35rem 0.6rem;font-size:0.8rem;background:none;border:none;cursor:pointer;color:var(--text)"
                  >{g.name}</button>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- User (asker) filter typeahead -->
        <div style="position:relative;min-width:14rem">
          <%= if @filter_user_id do %>
            <div style="display:flex;align-items:center;gap:0.4rem;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg)">
              <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                User: <strong>{@filter_username}</strong>
              </span>
              <button
                type="button"
                phx-click="clear_user_filter"
                class="btn-icon btn-xs"
              >✕</button>
            </div>
          <% else %>
            <input
              type="text"
              name="user_query"
              value={@user_query}
              autocomplete="off"
              phx-keyup="search_user"
              phx-debounce="250"
              placeholder="Filter by user…"
              style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
            />
            <%= if @user_results != [] do %>
              <div style="position:absolute;z-index:10;left:0;right:0;border:1px solid var(--border);border-radius:0.375rem;margin-top:0.15rem;background:var(--bg);max-height:14rem;overflow:auto;box-shadow:0 4px 12px rgba(0,0,0,0.15)">
                <%= for u <- @user_results do %>
                  <button
                    type="button"
                    phx-click="select_user"
                    phx-value-id={u.id}
                    phx-value-username={u.username}
                    class="block w-full text-left"
                    style="padding:0.35rem 0.6rem;font-size:0.8rem;background:none;border:none;cursor:pointer;color:var(--text)"
                  >{u.username}</button>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Group (crew) filter typeahead -->
        <div style="position:relative;min-width:14rem">
          <%= if @filter_group_id do %>
            <div style="display:flex;align-items:center;gap:0.4rem;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg)">
              <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                Group: <strong>{@filter_group_name}</strong>
              </span>
              <button
                type="button"
                phx-click="clear_group_filter"
                class="btn-icon btn-xs"
              >✕</button>
            </div>
          <% else %>
            <input
              type="text"
              name="group_search_query"
              value={@group_search_query}
              autocomplete="off"
              phx-keyup="search_group"
              phx-debounce="250"
              placeholder="Filter by group…"
              style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
            />
            <%= if @group_search_results != [] do %>
              <div style="position:absolute;z-index:10;left:0;right:0;border:1px solid var(--border);border-radius:0.375rem;margin-top:0.15rem;background:var(--bg);max-height:14rem;overflow:auto;box-shadow:0 4px 12px rgba(0,0,0,0.15)">
                <%= for g <- @group_search_results do %>
                  <button
                    type="button"
                    phx-click="select_group"
                    phx-value-id={g.id}
                    phx-value-name={g.name}
                    class="block w-full text-left"
                    style="padding:0.35rem 0.6rem;font-size:0.8rem;background:none;border:none;cursor:pointer;color:var(--text)"
                  >{g.name}</button>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <form id="questions-filter-status" phx-change="filter_status" phx-submit="filter_status">
          <select
            name="status"
            style="border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
          >
            <option value="">All statuses</option>
            <option value="answered" selected={@filter_status == "answered"}>Answered</option>
            <option value="pending" selected={@filter_status == "pending"}>Pending</option>
            <option value="refused" selected={@filter_status == "refused"}>Refused</option>
            <option value="pooled" selected={@filter_status == "pooled"}>Pooled (cache hit)</option>
            <option value="error" selected={@filter_status == "error"}>Error</option>
            <option value="needs_review" selected={@filter_status == "needs_review"}>
              Needs review (stale)
            </option>
            <option value="publish_pending" selected={@filter_status == "publish_pending"}>
              Stuck (publish gate)
            </option>
          </select>
        </form>
      </div>

      <form
        id="questions-search"
        phx-change="search"
        phx-submit="search"
        style="display:flex;gap:0.35rem;margin-bottom:1rem"
      >
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search questions / answers…"
          phx-debounce="300"
          style="flex:1;max-width:24rem;border:1px solid var(--border);border-radius:0.375rem;padding:0.3rem 0.6rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
        />
        <%= if @search != "" do %>
          <button
            type="button"
            phx-click="clear_search"
            class="btn-xs"
          >✕ Clear</button>
        <% end %>
      </form>

      <!-- Question list -->
      <div style="display:flex;flex-direction:column;gap:0.5rem">
        <%= if @questions == [] do %>
          <p style="color:var(--text-muted);font-size:0.8rem;padding:1rem 0">No questions found.</p>
        <% end %>

        <%= for q <- @questions do %>
          <% status = status_of(q) %>
          <% {status_label, pill_style} = status_label(status) %>
          <div style={"border:1px solid var(--border);border-radius:0.5rem;background:#{if @expanded_id == q.id, do: "var(--bg-subtle)", else: "var(--bg)"}"}>
            <!-- meta row -->
            <div style="display:flex;flex-wrap:wrap;align-items:center;gap:0.4rem 0.75rem;padding:0.45rem 0.75rem;border-bottom:1px solid var(--border-subtle)">
              <span style="font-size:0.7rem;color:var(--text-muted);white-space:nowrap">
                {Calendar.strftime(q.inserted_at, "%b %-d %H:%M")}
              </span>
              <span style="font-size:0.7rem;color:var(--text-secondary);font-weight:500">
                <%= if q.user do %>
                  <button
                    type="button"
                    phx-click="select_user"
                    phx-value-id={q.user.id}
                    phx-value-username={q.user.username}
                    title="Filter to this user's questions"
                    style="background:none;border:none;padding:0;font:inherit;color:inherit;cursor:pointer;text-decoration:underline;text-decoration-style:dotted"
                  >{q.user.username}</button>
                <% else %>
                  —
                <% end %>
                <span
                  :if={q.user}
                  style="color:var(--text-muted);font-weight:400"
                  title="Author reputation"
                > &middot; rep {q.user.reputation}</span>
              </span>
              <span
                style="font-size:0.7rem;color:var(--text-secondary);background:var(--bg-subtle);border:1px solid var(--border-subtle);padding:0.05rem 0.35rem;border-radius:0.25rem;max-width:14rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
                title={q.game && q.game.name}
              >
                {(q.game && q.game.name) || "—"}
              </span>
              <span style={"font-size:0.65rem;font-weight:600;padding:0.1rem 0.4rem;border-radius:0.25rem;#{pill_style}"}>{status_label}</span>
              <span
                :if={q.pooled}
                style="font-size:0.65rem;font-weight:600;padding:0.1rem 0.4rem;border-radius:0.25rem;background:var(--bg-subtle);border:1px solid var(--border-subtle);color:var(--text-secondary)"
                title="Cache-eligible; trust score drives ranking/promotion"
              >
                {if q.promoted or q.verified, do: "✓ trusted", else: "◌ provisional"} &middot; {:erlang.float_to_binary(
                  q.trust_score || 0.0,
                  decimals: 1
                )}
              </span>
              <span
                :if={q.needs_review}
                style="font-size:0.65rem;font-weight:600;padding:0.1rem 0.4rem;border-radius:0.25rem;background:rgba(212,160,23,0.15);border:1px solid #d4a017;color:#b8860b"
                title="A rulebook change may have made this answer stale. It won't serve from the cache until re-approved."
              >⚠ stale — review</span>
              <div style="margin-left:auto;display:flex;align-items:center;gap:0.5rem">
                <button
                  :if={q.needs_review}
                  type="button"
                  phx-click="clear_flag"
                  phx-value-id={q.id}
                  title="Re-approve this answer: clears the stale flag so it can serve from the cache again."
                  class="btn-xs"
                  style="background:#d4a017;border-color:#d4a017;color:#fff"
                >Re-approve</button>
                <button
                  :if={not q.browsable and q.citation_valid}
                  type="button"
                  phx-click="force_publish"
                  phx-value-id={q.id}
                  title="Manually clear the publish gate for this row, bypassing the automated screen."
                  class="btn-xs"
                  style="background:#d4a017;border-color:#d4a017;color:#fff"
                >Force publish</button>
                <select
                  phx-change="set_visibility"
                  phx-value-id={q.id}
                  name="visibility"
                  style="border:1px solid var(--border);border-radius:0.25rem;padding:0.1rem 0.25rem;font-size:0.7rem;background:var(--bg);color:var(--text)"
                >
                  <option value="private" selected={not q.promoted}>Private</option>
                  <option value="community" selected={q.promoted}>Community</option>
                </select>
                <%= if @confirm_delete_id == q.id do %>
                  <span style="font-size:0.7rem;color:var(--red);font-weight:600">Delete?</span>
                  <button
                    type="button"
                    phx-click="confirm_delete"
                    phx-value-id={q.id}
                    class="btn-danger-outline btn-xs"
                  >Yes</button>
                  <button
                    type="button"
                    phx-click="cancel_delete"
                    class="btn-xs"
                  >No</button>
                <% else %>
                  <button
                    type="button"
                    phx-click="delete_question"
                    phx-value-id={q.id}
                    data-confirm="Delete this question? This can't be undone."
                    class="btn-icon btn-xs"
                    title="Delete"
                  >✕</button>
                <% end %>
              </div>
            </div>

            <!-- question + expand -->
            <button
              type="button"
              phx-click="expand"
              phx-value-id={q.id}
              style="display:block;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:0.5rem 0.75rem"
            >
              <%= if @expanded_id == q.id do %>
                <span style="font-size:0.82rem;color:var(--text);line-height:1.45;word-break:break-word;display:block">
                  {admin_question_text(q)}
                </span>
                <span style="font-size:0.6rem;color:var(--text-muted);display:block;margin-top:0.2rem">▴ hide</span>
              <% else %>
                <span style="font-size:0.82rem;color:var(--text);display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
                  {admin_question_text(q)}
                </span>
                <span style="font-size:0.6rem;color:var(--text-muted);display:block;margin-top:0.1rem">▾ answer</span>
              <% end %>
            </button>

            <!-- expanded answer -->
            <%= if @expanded_id == q.id do %>
              <div style="margin:0 0.75rem 0.75rem;padding:0.65rem 0.75rem;background:var(--bg);border:1px solid var(--border-subtle);border-radius:0.35rem">
                <%= if q.canonical_question do %>
                  <p style="font-size:0.7rem;color:var(--accent-ink, var(--accent));font-weight:600;margin:0 0 0.35rem">
                    ★ Curated: {q.canonical_question}
                  </p>
                <% end %>
                <p style="font-size:0.72rem;font-weight:600;color:var(--text-muted);margin:0 0 0.3rem">
                  Answer
                </p>
                <p style="font-size:0.8rem;color:var(--text);white-space:pre-wrap;margin:0;line-height:1.5">
                  {admin_answer_text(q)}
                </p>
                <%= if q.cited_passage do %>
                  <div style="margin-top:0.5rem;padding:0.4rem 0.5rem;background:var(--bg-subtle);border-radius:0.25rem">
                    <%= if q.cited_source || q.cited_page do %>
                      <p style="display:flex;align-items:center;gap:0.35rem;margin:0 0 0.25rem;font-size:0.62rem;font-weight:700;letter-spacing:0.02em;text-transform:uppercase;color:var(--text-muted)">
                        <span>{q.cited_source || "Rulebook"}</span>
                        <%= if q.cited_page do %>
                          <span>p.{q.cited_page}</span>
                        <% end %>
                      </p>
                    <% end %>
                    <p style="margin:0;font-size:0.7rem;color:var(--text-muted);font-style:italic;line-height:1.4">
                      {q.cited_passage}
                    </p>
                  </div>
                <% end %>

                <div style="margin-top:0.6rem">
                  <RuleMavenWeb.AuditModal.audit_trigger
                    current_user={@current_user}
                    question_log_id={q.id}
                  />
                </div>

                <%!-- Curated FAQ text editor (replaces the old Threads merge) --%>
                <%= if @editing_canonical_id == q.id do %>
                  <form
                    id={"canonical-edit-#{q.id}"}
                    phx-change="canonical_change"
                    phx-submit="save_canonical"
                    style="margin-top:0.6rem;padding-top:0.6rem;border-top:1px solid var(--border-subtle)"
                  >
                    <label style="display:block;font-size:0.68rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">
                      Curated question
                    </label>
                    <textarea
                      name="canon_q"
                      rows="2"
                      style="width:100%;box-sizing:border-box;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.78rem;background:var(--bg-surface);color:var(--text);resize:vertical"
                    >{@canon_q}</textarea>
                    <label style="display:block;font-size:0.68rem;font-weight:600;color:var(--text-muted);margin:0.4rem 0 0.15rem">
                      Curated answer (markdown)
                    </label>
                    <textarea
                      name="canon_a"
                      rows="6"
                      style="width:100%;box-sizing:border-box;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.78rem;background:var(--bg-surface);color:var(--text);resize:vertical"
                    >{@canon_a}</textarea>
                    <p style="font-size:0.65rem;color:var(--text-muted);margin:0.3rem 0 0.4rem">
                      Serves and embeds in place of the raw Q&amp;A. Clear both fields to revert to the original. Promote to Community separately with the dropdown above.
                    </p>
                    <div style="display:flex;gap:0.4rem">
                      <button
                        type="submit"
                        class="btn-primary btn-xs"
                      >Save</button>
                      <button
                        type="button"
                        phx-click="cancel_canonical"
                        class="btn-xs"
                      >Cancel</button>
                    </div>
                  </form>
                <% else %>
                  <button
                    type="button"
                    phx-click="edit_canonical"
                    phx-value-id={q.id}
                    class="btn-xs"
                    style="margin-top:0.5rem"
                  >{if q.canonical_question, do: "✎ Edit curated FAQ text", else: "✎ Curate FAQ text"}</button>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <p style="font-size:0.72rem;color:var(--text-muted);margin-top:0.5rem">
        Showing up to 100 most recent.
      </p>
    </div>
    """
  end
end
