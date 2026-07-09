defmodule RuleMavenWeb.GameLive.ToolHelpers do
  @moduledoc """
  Shared function components + pure formatting helpers used by both the game
  page (`Show`) and the relocated table-tool markup (`ToolPanel`). Imported into
  both. Contains no LiveView state — event handlers stay in `Show` (LiveView
  resolves events module-wide regardless of which module rendered the markup).
  """
  use RuleMavenWeb, :html

  attr :key, :string, required: true
  attr :checked, :boolean, required: true
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :plain, :boolean, default: false

  def checklist_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_step"
      phx-value-key={@key}
      style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:#{if @plain, do: "0.2rem", else: "0.3rem"} 0;font-size:0.82rem;line-height:1.4;color:#{if @checked, do: "var(--text-muted)", else: "var(--text)"}"}
    >
      <span aria-hidden="true" style="flex-shrink:0">
        {if @checked, do: "☑️", else: "⬜"}
      </span>
      <%= if @plain do %>
        <span style={"flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere;#{if @checked, do: "text-decoration:line-through", else: ""}"}>
          {@title}
        </span>
      <% else %>
        <span style="flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere">
          <span style={"font-weight:600;#{if @checked, do: "text-decoration:line-through", else: ""}"}>
            {@title}
          </span>
          <%= if @detail not in [nil, "", "nil"] do %>
            <span style="display:block;font-size:0.74rem;color:var(--text-muted)">
              {@detail}
            </span>
          <% end %>
        </span>
      <% end %>
    </button>
    """
  end

  attr :hr, :map, required: true
  attr :editing, :boolean, required: true
  attr :owner?, :boolean, required: true
  attr :is_admin, :boolean, required: true

  def house_rule_row(assigns) do
    ~H"""
    <div style={
      "border-top:1px solid var(--border-subtle);padding:0.5rem 0;font-size:0.82rem" <>
        if(@owner? and not @hr.enabled, do: ";opacity:0.55", else: "")
    }>
      <%= if @editing do %>
        <form
          phx-submit="edit_house_rule"
          phx-value-id={@hr.id}
          style="display:flex;flex-direction:column;gap:0.35rem"
        >
          <input
            type="text"
            name="house_rule[title]"
            value={@hr.title}
            maxlength="80"
            style="font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text)"
          />
          <textarea
            name="house_rule[body]"
            maxlength="500"
            rows="3"
            style="font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text);resize:vertical"
          >{@hr.body}</textarea>
          <div style="display:flex;gap:0.4rem">
            <button
              type="submit"
              class="btn-primary btn-xs"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel_edit_house_rule"
              class="btn-xs"
            >
              Cancel
            </button>
          </div>
        </form>
      <% else %>
        <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.5rem">
          <div style="flex:1;min-width:0">
            <div style="display:flex;align-items:center;gap:0.4rem;flex-wrap:wrap;margin-bottom:0.2rem">
              <span style="font-weight:600;color:var(--text)">
                {if @hr.title not in [nil, ""], do: @hr.title, else: String.slice(@hr.body, 0, 40)}
              </span>

              <%= cond do %>
                <% @hr.check_status == "pending" -> %>
                  <span
                    style="font-size:0.65rem;color:var(--text-muted);font-weight:600"
                    data-testid="hr-pending"
                  >
                    ⏳ pending
                  </span>
                <% @hr.check_status in ["stale", "failed"] -> %>
                  <button
                    type="button"
                    phx-click="recheck_house_rule"
                    phx-value-id={@hr.id}
                    style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.62rem;cursor:pointer;padding:0.1rem 0.4rem;color:var(--text-muted);font-weight:600"
                  >
                    {if @hr.check_status == "stale",
                      do: "Stale — re-check",
                      else: "Check failed — retry"}
                  </button>
                <% @hr.check_status == "done" -> %>
                  <% {emoji, label} = house_rule_stamp(@hr.verdict) %>
                  <span style="display:inline-flex;align-items:center;gap:0.25rem;padding:0.1rem 0.4rem;border-radius:999px;background:var(--bg-subtle);font-weight:700;font-size:0.62rem;letter-spacing:0.02em;text-transform:uppercase;color:var(--text)">
                    <span aria-hidden="true">{emoji}</span> {label}
                  </span>
                <% true -> %>
              <% end %>
            </div>

            <details>
              <summary style="cursor:pointer;font-size:0.72rem;color:var(--text-muted)">
                {String.slice(@hr.body, 0, 60)}{if String.length(@hr.body) > 60, do: "…"}
              </summary>
              <p style="margin:0.3rem 0 0;color:var(--text)">{@hr.body}</p>
              <%= if @hr.raw_quote not in [nil, ""] do %>
                <blockquote style="margin:0.3rem 0 0;padding:0.3rem 0.6rem;border-left:2px solid var(--border);color:var(--text-muted);font-style:italic;font-size:0.74rem">
                  {@hr.raw_quote}
                </blockquote>
              <% end %>
              <%= if @hr.check_note not in [nil, ""] do %>
                <p style="margin:0.3rem 0 0;font-size:0.74rem;color:var(--text-muted)">
                  {@hr.check_note}
                </p>
              <% end %>
            </details>
          </div>

          <div style="display:flex;align-items:center;gap:0.3rem;flex-shrink:0">
            <%= if @owner? do %>
              <%!-- Three separate axes, so three separate controls. `On/Off` is
                    whether the rule applies at this user's table; the sharing
                    pill is who else can see it. Both carry a visible word — a
                    bare icon's meaning lived only in `title`, which a touch
                    device never shows. --%>
              <button
                type="button"
                phx-click="toggle_house_rule_enabled"
                phx-value-id={@hr.id}
                aria-pressed={to_string(@hr.enabled)}
                data-testid="hr-enabled-toggle"
                title={
                  if @hr.enabled,
                    do: "On — applies to your answers. Click to turn off.",
                    else: "Off — ignored in your answers. Click to turn on."
                }
                class="btn-xs"
                style={hr_toggle_style(@hr.enabled)}
              >{if @hr.enabled, do: "On", else: "Off"}</button>
              <button
                type="button"
                phx-click="toggle_house_rule_visibility"
                phx-value-id={@hr.id}
                data-testid="hr-visibility-toggle"
                title={
                  if @hr.visibility == "community",
                    do: "Shared with the community — click to make it private",
                    else: "Private to you — click to share it"
                }
                class="btn-xs"
                style="display:inline-flex;align-items:center;gap:0.2rem;font-size:0.62rem;font-weight:600"
              >
                <span aria-hidden="true">{if @hr.visibility == "community", do: "🌐", else: "🔒"}</span>
                <span>{if @hr.visibility == "community", do: "Shared", else: "Private"}</span>
              </button>
              <button
                type="button"
                phx-click="start_edit_house_rule"
                phx-value-id={@hr.id}
                class="btn-icon btn-xs"
              >✏️</button>
              <button
                type="button"
                phx-click="delete_house_rule"
                phx-value-id={@hr.id}
                data-confirm="Delete this house rule?"
                class="btn-icon btn-xs"
              >🗑️</button>
            <% end %>
            <%= if @is_admin and not @owner? do %>
              <button
                type="button"
                phx-click="block_house_rule"
                phx-value-id={@hr.id}
                title={
                  if @hr.blocked, do: "Blocked — click to unblock", else: "Block this house rule"
                }
                class="btn-icon btn-xs"
              >{if @hr.blocked, do: "🚫", else: "🛑"}</button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # On uses the accent/accent-text pair — the one pairing every theme is
  # contrast-tested on. Off stays --text-secondary (not --text-muted, which
  # fails the floor against --bg-subtle).
  defp hr_toggle_style(true),
    do:
      "font-size:0.62rem;font-weight:700;background:var(--accent);" <>
        "color:var(--accent-text,#fff);border-color:var(--accent-ink,var(--accent))"

  defp hr_toggle_style(false),
    do:
      "font-size:0.62rem;font-weight:700;background:var(--bg-subtle);" <>
        "color:var(--text-secondary);border:1px solid var(--border)"

  # Verdict → {emoji, label} stamp for a house rule's RAW relationship.
  def house_rule_stamp("matches"), do: {"✅", "Matches RAW"}
  def house_rule_stamp("fills_gap"), do: {"🧩", "Fills a gap"}
  def house_rule_stamp("overrides"), do: {"🔀", "Overrides RAW"}
  def house_rule_stamp(_), do: {"🤔", "Unclear"}

  # Strip [Page N] markers and collapse whitespace for friendly card display.
  def clean_rule_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\[Page\s*\d+\]/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The teach spoken aloud: its filled lines in goal→loop→win→trap order.
  def teach_speech(pitch) do
    ~w(goal loop win trap)
    |> Enum.map(&pitch[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Heavier games get a longer suggested turn clock. Weight is BGG's 1–5
  # complexity rating; games without one get the 60s default.
  def suggested_turn_seconds(%{weight: w}) when is_float(w) do
    cond do
      w >= 3.5 -> 120
      w >= 2.5 -> 90
      w >= 1.8 -> 60
      true -> 45
    end
  end

  def suggested_turn_seconds(_game), do: 60
end
