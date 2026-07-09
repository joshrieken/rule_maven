defmodule RuleMavenWeb.GameLive.ToolPanel do
  @moduledoc """
  Shared host for every table tool. Renders the currently-:expanded tool as a
  floating panel (draggable card on desktop, bottom sheet on mobile — behavior
  supplied by the FloatingPanel JS hook) plus a dock of peek pills for
  :minimized tools. Tool *content* is relocated verbatim from show.ex; the only
  new markup is the panel chrome (drag handle, minimize/close) and the dock.

  Visibility is driven by `@tool_states` (see Show: open_tool/minimize_tool/
  close_tool/expand_tool). Each tool's own state lives in the passed assigns, so
  closing a panel never resets it.
  """
  use RuleMavenWeb, :html
  import RuleMavenWeb.GameLive.ToolHelpers
  alias RuleMavenWeb.GameLive.ToolRegistry

  # `assigns` is the full LiveView assigns map (needs every tool's state).
  def tool_panel(assigns) do
    expanded = Enum.find_value(assigns.tool_states, fn {id, s} -> s == :expanded && id end)
    minimized = for {id, :minimized} <- assigns.tool_states, do: id
    assigns = assign(assigns, expanded: expanded, minimized: minimized)

    ~H"""
    <div :if={@expanded} data-tool-panel={@expanded} data-tool-state="expanded">
      <.panel_frame id={@expanded}>
        {render_tool(assign(assigns, :tool, @expanded))}
      </.panel_frame>
    </div>

    <div :if={@minimized != []} id="tool-tray" phx-hook="ToolTray" class="tool-dock" data-tool-dock>
      <div class="tool-dock__inner">
        <span
          :for={id <- @minimized}
          class="tool-dock__pill"
          data-dock-pill={id}
        >
          <button
            type="button"
            phx-click="expand_tool"
            phx-value-tool={id}
            class="tool-dock__restore"
            title={"Restore #{ToolRegistry.tool(id).label}"}
          >
            <span aria-hidden="true">{ToolRegistry.tool(id).emoji}</span>
            {ToolRegistry.tool(id).label}
          </button>
          <button
            type="button"
            phx-click="close_tool"
            phx-value-tool={id}
            class="tool-dock__close"
            title={"Close #{ToolRegistry.tool(id).label}"}
            aria-label={"Close #{ToolRegistry.tool(id).label}"}
          >✕</button>
        </span>
      </div>
    </div>
    """
  end

  attr :id, :atom, required: true
  slot :inner_block, required: true

  defp panel_frame(assigns) do
    tool = ToolRegistry.tool(assigns.id)
    assigns = assign(assigns, :tool, tool)

    ~H"""
    <div
      id={"tool-panel-#{@id}"}
      phx-hook="FloatingPanel"
      data-tool={@id}
      class="tool-panel"
    >
      <div class="tool-panel__bar" data-drag-handle>
        <span class="tool-panel__title">
          <span aria-hidden="true">{@tool.emoji}</span> {@tool.label}
        </span>
        <span class="tool-panel__controls">
          <button
            type="button"
            phx-click="minimize_tool"
            phx-value-tool={@id}
            class="btn-icon btn-sm"
            title="Minimize"
            aria-label="Minimize"
          >–</button>
          <button
            type="button"
            phx-click="close_tool"
            phx-value-tool={@id}
            class="btn-icon btn-sm"
            title="Close"
            aria-label="Close"
          >✕</button>
        </span>
      </div>
      <div class="tool-panel__body">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # A tool that has no cached data for this game yet.
  defp tool_unavailable(assigns) do
    ~H"""
    <p style="color:var(--text-muted);font-size:0.82rem;line-height:1.5;margin:0">
      Not available for this game yet.
    </p>
    """
  end

  # ── One clause per tool. Content relocated from show.ex, with the outer
  # <details>/<summary>/card wrapper stripped (panel_frame supplies the
  # container + title). Inner controls, phx-click/phx-hook/:if/:for and
  # CSS-var styles are kept verbatim. ──

  defp render_tool(%{tool: :dyk} = assigns) do
    ~H"""
    <%= if @rule_card do %>
      <div style="display:flex;justify-content:flex-end;margin-bottom:0.5rem">
        <button
          type="button"
          phx-click="shuffle_rule"
          title="Another rule"
          style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.65rem;cursor:pointer;padding:0.12rem 0.5rem;color:var(--text-muted);font-weight:600"
        >🔀 Shuffle</button>
      </div>
      <p style="font-size:0.85rem;line-height:1.55;color:var(--text);margin:0">
        {clean_rule_text(@rule_card.content)}
      </p>
      <%= if @rule_card.page_number do %>
        <div style="margin-top:0.5rem;font-size:0.65rem;font-weight:600;text-transform:uppercase;letter-spacing:0.02em;color:var(--text-muted)">
          📎 Rulebook · p.{@rule_card.page_number}
        </div>
      <% end %>
    <% else %>
      <.tool_unavailable />
    <% end %>
    """
  end

  defp render_tool(%{tool: :first_player} = assigns) do
    ~H"""
    <%= if @fp_selectors != [] do %>
      <div style="display:flex;justify-content:flex-end;margin-bottom:0.5rem">
        <button
          type="button"
          phx-click="roll_first_player"
          style="background:none;border:1px solid var(--border);border-radius:999px;font-size:0.65rem;cursor:pointer;padding:0.12rem 0.5rem;color:var(--text-muted);font-weight:600"
        >
          {if @fp_pick, do: "🎲 Roll again", else: "🎲 Roll"}
        </button>
      </div>
      <p style="font-size:0.85rem;line-height:1.55;color:var(--text);margin:0">
        <%= if @fp_pick do %>
          {@fp_pick}
        <% else %>
          <span style="color:var(--text-muted)">
            Roll for a fun, on-theme way to pick who starts.
          </span>
        <% end %>
      </p>
    <% else %>
      <.tool_unavailable />
    <% end %>
    """
  end

  defp render_tool(%{tool: :turn} = assigns) do
    ~H"""
    <% phase = Enum.at(@turn_flow, @turn_phase) %>
    <% phase_count = length(@turn_flow) %>
    <%= if @turn_flow == [] do %>
      <.tool_unavailable />
    <% else %>
      <%= if phase do %>
        <div>
          <div style="display:flex;justify-content:space-between;align-items:center;font-size:0.65rem;color:var(--text-muted);font-weight:600;margin-bottom:0.4rem">
            <span>{if phase_count > 1, do: "Phase #{@turn_phase + 1} of #{phase_count}", else: "Your turn"}</span>
            <button
              :if={@turn_phase > 0}
              type="button"
              phx-click="turn_restart"
              style="background:none;border:none;color:var(--text-muted);font-size:0.65rem;cursor:pointer;padding:0;text-decoration:underline"
            >↺ Restart turn</button>
          </div>
          <p style="font-size:0.9rem;font-weight:700;color:var(--text);margin:0 0 0.15rem">
            {phase["name"]}
          </p>
          <p :if={phase["note"] not in [nil, ""]} style="font-size:0.75rem;color:var(--text-secondary);margin:0 0 0.5rem;line-height:1.45">
            {phase["note"]}
          </p>
          <div style="display:flex;flex-direction:column;gap:0.4rem;margin-top:0.5rem">
            <div
              :for={a <- phase["actions"] || []}
              style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.45rem 0.55rem"
            >
              <div style="font-size:0.82rem;font-weight:600;color:var(--text)">{a["label"]}</div>
              <div :if={a["rule"] not in [nil, ""]} style="font-size:0.76rem;color:var(--text-secondary);line-height:1.45;margin-top:0.1rem">
                {a["rule"]}
              </div>
            </div>
          </div>
          <div :if={phase_count > 1} style="display:flex;justify-content:space-between;gap:0.5rem;margin-top:0.7rem">
            <button
              type="button"
              phx-click="turn_prev"
              disabled={@turn_phase == 0}
              class="btn-outline btn-xs"
              style={"opacity:#{if @turn_phase == 0, do: "0.4", else: "1"}"}
            >← Back</button>
            <button
              type="button"
              phx-click="turn_next"
              disabled={@turn_phase >= phase_count - 1}
              class="btn-xs"
              style={"background:var(--accent);color:var(--accent-text,#fff);border-color:var(--accent);opacity:#{if @turn_phase >= phase_count - 1, do: "0.4", else: "1"}"}
            >Next phase →</button>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp render_tool(%{tool: :teach} = assigns) do
    ~H"""
    <%= if @teach_pitch == %{} do %>
      <.tool_unavailable />
    <% else %>
      <dl style="margin:0;display:flex;flex-direction:column;gap:0.5rem">
        <div
          :for={{k, emoji, label} <- [{"goal", "🎯", "Goal"}, {"loop", "🔁", "On your turn"}, {"win", "🏆", "Winning"}, {"trap", "⚠️", "Don't forget"}]}
          :if={@teach_pitch[k]}
          style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.45rem 0.55rem"
        >
          <dt style="font-size:0.62rem;font-weight:800;letter-spacing:0.04em;text-transform:uppercase;color:var(--text-muted)">
            <span aria-hidden="true">{emoji}</span> {label}
          </dt>
          <dd style="margin:0.12rem 0 0;font-size:0.82rem;line-height:1.5;color:var(--text)">
            {@teach_pitch[k]}
          </dd>
        </div>
      </dl>
      <button
        type="button"
        id="teach-read"
        phx-hook="ReadAloud"
        data-speak={teach_speech(@teach_pitch)}
        aria-pressed="false"
        class="btn-outline btn-xs"
        style="margin-top:0.6rem"
        title="Read the teach aloud"
      >🔊 Read aloud</button>
    <% end %>
    """
  end

  defp render_tool(%{tool: :mistakes} = assigns) do
    ~H"""
    <%= if @common_mistakes == [] do %>
      <.tool_unavailable />
    <% else %>
      <div style="margin:0;display:flex;flex-direction:column;gap:0.5rem">
        <div
          :for={m <- @common_mistakes}
          style="font-size:0.8rem;line-height:1.5;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.45rem 0.55rem"
        >
          <div style="display:flex;gap:0.4rem;color:var(--text-muted)">
            <span style="color:var(--red);font-weight:700;flex-shrink:0" aria-hidden="true">✗</span>
            <span>{m["wrong"]}</span>
          </div>
          <div style="display:flex;gap:0.4rem;margin-top:0.2rem;color:var(--text)">
            <span style="color:var(--green);font-weight:700;flex-shrink:0" aria-hidden="true">✓</span>
            <span>{m["right"]}</span>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_tool(%{tool: :quiz} = assigns) do
    ~H"""
    <%= if @quiz == [] do %>
      <.tool_unavailable />
    <% else %>
      <% cur = Enum.at(@quiz, @quiz_idx) %>
      <%= if cur do %>
        <div>
          <div style="display:flex;justify-content:space-between;font-size:0.65rem;color:var(--text-muted);font-weight:600;margin-bottom:0.4rem">
            <span>Question {@quiz_idx + 1} of {length(@quiz)}</span>
            <span>Score {elem(@quiz_score, 0)}/{elem(@quiz_score, 1)}</span>
          </div>
          <p style="font-size:0.85rem;font-weight:600;color:var(--text);margin:0 0 0.5rem;line-height:1.5">
            {cur["q"]}
          </p>
          <div style="display:flex;flex-direction:column;gap:0.35rem">
            <%= for {choice, i} <- Enum.with_index(cur["choices"]) do %>
              <button
                type="button"
                phx-click="quiz_answer"
                phx-value-choice={i}
                disabled={@quiz_choice != nil}
                style={"text-align:left;border-radius:0.4rem;padding:0.45rem 0.7rem;font-size:0.8rem;cursor:#{if @quiz_choice, do: "default", else: "pointer"};white-space:normal;word-break:break-word;line-height:1.45;border:1px solid #{cond do
                  @quiz_choice != nil and i == cur["answer"] -> "var(--green)"
                  @quiz_choice == i -> "var(--red,#c0392b)"
                  true -> "var(--border)"
                end};background:#{cond do
                  @quiz_choice != nil and i == cur["answer"] -> "color-mix(in srgb, var(--green) 14%, var(--bg-surface))"
                  @quiz_choice == i -> "color-mix(in srgb, var(--red,#c0392b) 12%, var(--bg-surface))"
                  true -> "var(--bg-subtle)"
                end};color:var(--text);opacity:1"}
              >
                {choice}
                <%= if @quiz_choice != nil and i == cur["answer"] do %>
                  <span aria-hidden="true"> ✅</span>
                <% end %>
                <%= if @quiz_choice == i and i != cur["answer"] do %>
                  <span aria-hidden="true"> ❌</span>
                <% end %>
              </button>
            <% end %>
          </div>
          <%= if @quiz_choice != nil do %>
            <p style="font-size:0.75rem;color:var(--text-secondary);margin:0.5rem 0 0;line-height:1.5">
              💡 {cur["why"]}
            </p>
            <button
              type="button"
              phx-click="quiz_next"
              style="margin-top:0.6rem;background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.35rem 0.9rem;border-radius:2rem;font-weight:600;font-size:0.75rem;cursor:pointer"
            >
              {if @quiz_idx + 1 < length(@quiz), do: "Next question →", else: "Finish"}
            </button>
          <% end %>
        </div>
      <% else %>
        <div style="text-align:center">
          <p style="font-size:0.9rem;font-weight:700;color:var(--text);margin:0">
            🏁 {elem(@quiz_score, 0)}/{elem(@quiz_score, 1)} correct
          </p>
          <button
            type="button"
            phx-click="quiz_restart"
            style="margin-top:0.5rem;background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.35rem 0.9rem;border-radius:2rem;font-weight:600;font-size:0.75rem;cursor:pointer"
          >
            🔀 Play again
          </button>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp render_tool(%{tool: :scorepad} = assigns) do
    ~H"""
    <%= if @score_categories == [] do %>
      <.tool_unavailable />
    <% else %>
      <div
        id="score-pad"
        phx-hook="ScorePad"
        phx-update="ignore"
        data-game={@game.id}
        data-categories={Jason.encode!(@score_categories)}
      ></div>
    <% end %>
    """
  end

  defp render_tool(%{tool: :timer} = assigns) do
    ~H"""
    <% suggested = suggested_turn_seconds(@game) %>
    <div
      id="turn-timer"
      phx-hook="TurnTimer"
      phx-update="ignore"
      data-seconds={suggested}
      style="text-align:center"
    >
      <div
        data-timer-display
        style="font-size:2.2rem;font-weight:800;font-variant-numeric:tabular-nums;color:var(--text);line-height:1"
      >
      </div>
      <div style="display:flex;justify-content:center;gap:0.4rem;margin-top:0.6rem">
        <button
          type="button"
          data-timer-action="startpause"
          style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.35rem 0.9rem;border-radius:2rem;font-weight:600;font-size:0.75rem;cursor:pointer"
        >▶ Start</button>
        <button
          type="button"
          data-timer-action="reset"
          style="background:none;border:1px solid var(--border);border-radius:2rem;padding:0.35rem 0.9rem;font-weight:600;font-size:0.75rem;color:var(--text-muted);cursor:pointer"
        >↺ Reset</button>
      </div>
      <div style="display:flex;justify-content:center;gap:0.3rem;margin-top:0.5rem;flex-wrap:wrap">
        <%= for secs <- [30, 60, 90, 120] do %>
          <button
            type="button"
            data-timer-action="preset"
            data-seconds={secs}
            style={"background:none;border:1px solid #{if secs == suggested, do: "var(--accent)", else: "var(--border)"};border-radius:999px;padding:0.12rem 0.5rem;font-size:0.65rem;font-weight:600;color:#{if secs == suggested, do: "var(--accent)", else: "var(--text-muted)"};cursor:pointer"}
          >{div(secs, 60)}:{String.pad_leading(to_string(rem(secs, 60)), 2, "0")}</button>
        <% end %>
      </div>
      <div style="margin-top:0.4rem;font-size:0.62rem;color:var(--text-muted)">
        Suggested for this game's weight: {div(suggested, 60)}:{String.pad_leading(
          to_string(rem(suggested, 60)),
          2,
          "0"
        )} per turn
      </div>
    </div>
    """
  end

  defp render_tool(%{tool: :checklist} = assigns) do
    ~H"""
    <%= if @setup_checklist && (@setup_checklist["components"] != [] || @setup_checklist["setup"] != []) do %>
      <% delta_total =
        Enum.reduce(@expansion_deltas, 0, fn {_e, d}, acc ->
          acc + length(d["components"]) + length(d["setup"])
        end) %>
      <% total =
        length(@setup_checklist["components"]) + length(@setup_checklist["setup"]) +
          delta_total %>
      <% done = MapSet.size(@checklist_done) %>
      <div
        id="setup-checklist"
        phx-hook="ChecklistStore"
        data-game-id={@game.id}
      >
        <div style="display:flex;align-items:center;justify-content:flex-end;gap:0.5rem;margin-bottom:0.6rem">
          <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">
            {done}/{total} done
          </span>
          <button
            type="button"
            phx-click="reset_checklist"
            class="btn-xs"
          >🗑️ Clear</button>
        </div>

        <%= if @setup_checklist["components"] != [] do %>
          <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.3rem 0 0.3rem">
            Gather
          </div>
          <%= for {item, i} <- Enum.with_index(@setup_checklist["components"]) do %>
            <% key = "c-#{i}" %>
            <.checklist_item
              key={key}
              checked={MapSet.member?(@checklist_done, key)}
              title={item}
              plain={true}
            />
          <% end %>
        <% end %>

        <%= if @setup_checklist["setup"] != [] do %>
          <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.6rem 0 0.3rem">
            Steps
          </div>
          <%= for {step, i} <- Enum.with_index(@setup_checklist["setup"]) do %>
            <% key = "s-#{i}" %>
            <.checklist_item
              key={key}
              checked={MapSet.member?(@checklist_done, key)}
              title={step["title"]}
              detail={step["detail"]}
            />
          <% end %>
        <% end %>

        <%= for {exp, delta} <- @expansion_deltas do %>
          <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--accent);margin:0.8rem 0 0.3rem">
            ➕ {exp.name}
          </div>
          <%= for {item, i} <- Enum.with_index(delta["components"]) do %>
            <% key = "xc-#{exp.id}-#{i}" %>
            <.checklist_item
              key={key}
              checked={MapSet.member?(@checklist_done, key)}
              title={item}
              plain={true}
            />
          <% end %>
          <%= for {step, i} <- Enum.with_index(delta["setup"]) do %>
            <% key = "xs-#{exp.id}-#{i}" %>
            <.checklist_item
              key={key}
              checked={MapSet.member?(@checklist_done, key)}
              title={step["title"]}
              detail={step["detail"]}
            />
          <% end %>
        <% end %>

        <button
          type="button"
          phx-click="reset_checklist"
          class="btn-xs"
          style="margin-top:0.6rem"
        >🗑️ Clear</button>
      </div>
    <% else %>
      <.tool_unavailable />
    <% end %>
    """
  end

  defp render_tool(%{tool: :house_rules} = assigns) do
    ~H"""
    <div data-tour="house-rules" style="text-align:left">
      <div style="display:flex;align-items:center;justify-content:space-between;margin:0.3rem 0 0.3rem">
        <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted)">
          Your house rules
        </div>
        <span style="font-size:0.68rem;color:var(--text-muted);font-weight:600">
          {length(@house_rules) + length(@community_house_rules)} rules
        </span>
      </div>

      <%= for hr <- @house_rules do %>
        <.house_rule_row
          hr={hr}
          editing={@hr_editing_id == hr.id}
          owner?={true}
          is_admin={@is_admin}
        />
      <% end %>

      <%= if @house_rules == [] do %>
        <p style="font-size:0.76rem;color:var(--text-muted);margin:0 0 0.4rem">
          No house rules yet — add one below.
        </p>
      <% end %>

      <%= if @hr_form_open do %>
        <form
          id="house-rule-form"
          phx-submit="add_house_rule"
          style="margin-top:0.5rem;display:flex;flex-direction:column;gap:0.4rem"
        >
          <input
            type="text"
            name="house_rule[title]"
            placeholder="Title (optional)"
            maxlength="80"
            style="font-size:0.8rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text)"
          />
          <textarea
            name="house_rule[body]"
            placeholder="Describe the house rule…"
            maxlength="500"
            rows="3"
            style="font-size:0.8rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text);resize:vertical"
          ></textarea>
          <div style="display:flex;gap:0.4rem">
            <button
              type="submit"
              class="btn-primary btn-xs"
            >
              Add house rule
            </button>
            <button
              type="button"
              phx-click="toggle_house_rule_form"
              class="btn-xs"
            >
              Cancel
            </button>
          </div>
        </form>
      <% else %>
        <button
          type="button"
          phx-click="toggle_house_rule_form"
          class="btn-xs"
          style="margin-top:0.3rem;border-style:dashed"
        >
          + Add a house rule
        </button>
      <% end %>

      <%= if @community_house_rules != [] do %>
        <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--text-muted);margin:0.8rem 0 0.3rem">
          Community house rules
        </div>

        <%= for hr <- @community_house_rules do %>
          <.house_rule_row hr={hr} editing={false} owner?={false} is_admin={@is_admin} />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_tool(assigns) do
    ~H"""
    <p style="color:var(--text-muted)">Tool coming soon.</p>
    """
  end
end
