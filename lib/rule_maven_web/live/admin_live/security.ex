defmodule RuleMavenWeb.AdminLive.Security do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Security, Games, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      {:ok,
       socket
       |> assign(page_title: "Security")
       |> assign(tab: "blocked")
       |> load_blocked()
       |> load_patterns()
       |> assign(
         new_pattern: "",
         new_category: "instruction_override",
         new_note: "",
         add_error: nil
       )}
    else
      {:ok, socket |> put_flash(:error, "Access denied.") |> push_navigate(to: ~p"/")}
    end
  end

  defp load_blocked(socket), do: assign(socket, blocked: Security.list_blocked_questions())
  defp load_patterns(socket), do: assign(socket, patterns: Security.list_patterns())

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  def handle_event("unblock", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.blocked, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Security.unblock_question(q) do
          {:ok, updated} ->
            Audit.log(socket.assigns.current_user, "security.unblock",
              target_type: "question",
              target_id: q.id,
              target_label: q.question
            )

            expansion_ids = []
            recent_context = []

            Oban.insert(
              RuleMaven.Workers.AskWorker.new(%{
                "game_id" => updated.game_id,
                "question" => updated.question,
                "question_log_id" => updated.id,
                "user_id" => updated.user_id,
                # Carry the row's group across the re-queue. AskWorker also reads
                # the row's own group_id (args are untrusted), so this is belt and
                # braces — without either, the re-run would write browsable: true
                # on a group row and skip the publish check.
                "group_id" => updated.group_id,
                "expansion_ids" => expansion_ids,
                "recent_context" => recent_context
              })
            )

            {:noreply, socket |> load_blocked() |> put_flash(:info, "Unblocked and re-queued.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unblock.")}
        end
    end
  end

  def handle_event("delete_blocked", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.blocked, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.delete_question(q, socket.assigns.current_user) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "security.delete_blocked",
              target_type: "question",
              target_id: q.id,
              target_label: q.question
            )

            {:noreply, load_blocked(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete that entry.")}
        end
    end
  end

  def handle_event("toggle_pattern", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.patterns, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      p ->
        case Security.toggle_pattern(p) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "security.toggle_pattern",
              target_type: "pattern",
              target_id: p.id,
              target_label: p.pattern,
              metadata: %{"enabled" => !p.enabled}
            )

            {:noreply, load_patterns(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't update the pattern.")}
        end
    end
  end

  def handle_event("delete_pattern", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.patterns, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      p ->
        case Security.delete_pattern(p) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "security.delete_pattern",
              target_type: "pattern",
              target_id: p.id,
              target_label: p.pattern
            )

            {:noreply, load_patterns(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete the pattern.")}
        end
    end
  end

  def handle_event(
        "add_pattern",
        %{"pattern" => pattern, "category" => category, "note" => note},
        socket
      ) do
    case Security.create_pattern(%{pattern: pattern, category: category, note: note}) do
      {:ok, created} ->
        Audit.log(socket.assigns.current_user, "security.add_pattern",
          target_type: "pattern",
          target_id: created.id,
          target_label: created.pattern,
          metadata: %{"category" => category}
        )

        {:noreply,
         socket |> assign(new_pattern: "", new_note: "", add_error: nil) |> load_patterns()}

      {:error, changeset} ->
        msg = changeset.errors |> Enum.map_join(", ", fn {f, {m, _}} -> "#{f} #{m}" end)
        {:noreply, assign(socket, add_error: msg)}
    end
  end

  def handle_event("form_change", params, socket) do
    {:noreply,
     assign(socket,
       new_pattern: params["pattern"] || socket.assigns.new_pattern,
       new_category: params["category"] || socket.assigns.new_category,
       new_note: params["note"] || socket.assigns.new_note
     )}
  end

  defp category_label("instruction_override"), do: "Override"
  defp category_label("role_change"), do: "Role change"
  defp category_label("prompt_extraction"), do: "Extraction"
  defp category_label("jailbreak"), do: "Jailbreak"
  defp category_label("token_injection"), do: "Token"
  defp category_label("future_behavior"), do: "Future behavior"
  defp category_label("authority_spoofing"), do: "Authority"
  defp category_label("encoding"), do: "Encoding"
  defp category_label("authority_social"), do: "Social engineering"
  defp category_label("fictional_framing"), do: "Fictional framing"
  defp category_label("output_manipulation"), do: "Output manipulation"
  defp category_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>
      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 1rem">Security</h1>

      <%!-- Tabs --%>
      <div style="display:flex;gap:0;border-bottom:1px solid var(--border);margin-bottom:1.25rem">
        <%= for {id, label} <- [{"blocked", "Blocked (#{length(@blocked)})"}, {"patterns", "Patterns (#{length(@patterns)})"}] do %>
          <button
            type="button"
            phx-click="tab"
            phx-value-tab={id}
            style={"background:none;border:none;padding:0.5rem 1rem;font-size:0.85rem;font-weight:600;cursor:pointer;border-bottom:2px solid #{if @tab == id, do: "var(--accent)", else: "transparent"};color:#{if @tab == id, do: "var(--accent)", else: "var(--text-muted)"}"}
          >{label}</button>
        <% end %>
      </div>

      <%!-- Blocked Questions Tab --%>
      <%= if @tab == "blocked" do %>
        <%= if @blocked == [] do %>
          <p style="color:var(--text-muted);font-size:0.85rem">No blocked questions.</p>
        <% else %>
          <div style="border:1px solid var(--border);border-radius:0.5rem;overflow-x:auto">
            <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
              <colgroup>
                <col style="width:7rem" />
                <col style="width:6rem" />
                <col style="width:8rem" />
                <col />
                <col style="width:9.5rem" />
              </colgroup>
              <thead>
                <tr style="background:var(--bg-subtle);text-align:left">
                  <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">When</th>
                  <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">User</th>
                  <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">Game</th>
                  <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">
                    Question
                  </th>
                  <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= for q <- @blocked do %>
                  <tr style="border-top:1px solid var(--border-subtle)">
                    <td style="padding:0.45rem 0.75rem;white-space:nowrap;color:var(--text-muted);font-size:0.75rem">
                      {Calendar.strftime(q.inserted_at, "%b %-d %H:%M")}
                    </td>
                    <td style="padding:0.45rem 0.75rem;font-size:0.75rem;overflow:hidden">
                      <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text-secondary)">{(q.user &&
                                                                                                                                            q.user.username) ||
                        "—"}</span>
                    </td>
                    <td style="padding:0.45rem 0.75rem;font-size:0.75rem;overflow:hidden">
                      <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text-secondary)">{(q.game &&
                                                                                                                                            q.game.name) ||
                        "—"}</span>
                    </td>
                    <td style="padding:0.45rem 0.75rem;overflow:hidden">
                      <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:0.8rem;color:var(--text)">{q.question}</span>
                    </td>
                    <td style="padding:0.45rem 0.75rem">
                      <div style="display:flex;gap:0.35rem">
                        <button
                          type="button"
                          phx-click="unblock"
                          phx-value-id={q.id}
                          class="btn-xs"
                          style="border:1px solid var(--green);color:var(--green);background:none;white-space:nowrap"
                          title="Unblock and re-queue"
                        >↻ Unblock</button>
                        <button
                          type="button"
                          phx-click="delete_blocked"
                          phx-value-id={q.id}
                          data-confirm="Delete this blocked entry?"
                          class="btn-icon btn-xs"
                        >✕</button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      <% end %>

      <%!-- Patterns Tab --%>
      <%= if @tab == "patterns" do %>
        <%!-- Add pattern form --%>
        <form
          phx-submit="add_pattern"
          phx-change="form_change"
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;margin-bottom:1.25rem"
        >
          <div style="display:grid;grid-template-columns:1fr 10rem 1fr;gap:0.75rem;margin-bottom:0.6rem">
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.25rem">Pattern
              <span style="font-weight:400;opacity:0.7">(lowercase substring)</span></label>
              <input
                type="text"
                name="pattern"
                value={@new_pattern}
                placeholder="e.g. ignore all previous"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.35rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text);box-sizing:border-box"
              />
            </div>
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.25rem">Category</label>
              <select
                name="category"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.35rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text);box-sizing:border-box"
              >
                <%= for cat <- ~w[instruction_override role_change prompt_extraction jailbreak token_injection future_behavior authority_spoofing encoding authority_social fictional_framing output_manipulation] do %>
                  <option value={cat} selected={@new_category == cat}>{category_label(cat)}</option>
                <% end %>
              </select>
            </div>
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.25rem">Note
              <span style="font-weight:400;opacity:0.7">(optional)</span></label>
              <input
                type="text"
                name="note"
                value={@new_note}
                placeholder="Why this pattern?"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.35rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text);box-sizing:border-box"
              />
            </div>
          </div>
          <div style="display:flex;align-items:center;gap:0.75rem">
            <button
              type="submit"
              class="btn-primary btn-sm"
            >+ Add pattern</button>
            <%= if @add_error do %>
              <span style="font-size:0.75rem;color:var(--red)">{@add_error}</span>
            <% end %>
          </div>
        </form>

        <%!-- Patterns table --%>
        <div style="border:1px solid var(--border);border-radius:0.5rem;overflow-x:auto">
          <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
            <colgroup>
              <col />
              <col style="width:8.5rem" />
              <col style="width:8rem" />
              <col style="width:4.5rem" />
              <col style="width:7rem" />
            </colgroup>
            <thead>
              <tr style="background:var(--bg-subtle);text-align:left">
                <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">
                  Pattern
                </th>
                <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">
                  Category
                </th>
                <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">Note</th>
                <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">Status</th>
                <th style="padding:0.5rem 0.75rem;font-weight:600;color:var(--text-muted)">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              <%= for p <- @patterns do %>
                <tr style={"border-top:1px solid var(--border-subtle);#{if !p.enabled, do: "opacity:0.45"}"}>
                  <td style="padding:0.45rem 0.75rem;overflow:hidden">
                    <span style="display:block;font-family:monospace;font-size:0.75rem;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{p.pattern}</span>
                  </td>
                  <td style="padding:0.45rem 0.75rem;overflow:hidden">
                    <span style="display:inline-block;font-size:0.65rem;font-weight:600;padding:0.1rem 0.35rem;border-radius:0.2rem;background:var(--bg-subtle);color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%">{category_label(
                      p.category
                    )}</span>
                  </td>
                  <td style="padding:0.45rem 0.75rem;overflow:hidden">
                    <span style="display:block;font-size:0.73rem;color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{p.note ||
                      ""}</span>
                  </td>
                  <td style="padding:0.45rem 0.75rem">
                    <span style={"font-size:0.7rem;font-weight:600;#{if p.enabled, do: "color:var(--green)", else: "color:var(--text-muted)"}"}>
                      {if p.enabled, do: "On", else: "Off"}
                    </span>
                  </td>
                  <td style="padding:0.45rem 0.75rem">
                    <div style="display:flex;gap:0.35rem">
                      <button
                        type="button"
                        phx-click="toggle_pattern"
                        phx-value-id={p.id}
                        class="btn-xs"
                        style="white-space:nowrap"
                      >{if p.enabled, do: "Disable", else: "Enable"}</button>
                      <button
                        type="button"
                        phx-click="delete_pattern"
                        phx-value-id={p.id}
                        class="btn-icon btn-xs"
                        data-confirm="Delete this pattern?"
                      >✕</button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <p style="font-size:0.72rem;color:var(--text-muted);margin-top:0.5rem">
          Disabled patterns are skipped during detection but kept for reference.
        </p>
      <% end %>
    </div>
    """
  end
end
