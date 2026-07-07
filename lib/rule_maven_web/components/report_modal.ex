defmodule RuleMavenWeb.ReportModal do
  @moduledoc """
  Shared "why are you reporting this answer?" modal.

  The parent LiveView renders `<ReportModal.report_modal :if={@report_target} />`
  and handles three events: `"cancel_report"` (close), `"submit_report"`
  (form submit with `"reason"` + optional `"detail"`), and whatever event it
  uses to open the modal (assigning its own `report_target`).

  `compose_reason/1` turns the submitted params into the single reason string
  stored on the flag.
  """
  use Phoenix.Component

  alias RuleMaven.Games

  @other_label "Other"

  def report_modal(assigns) do
    assigns = assign(assigns, reasons: Games.report_reasons(), other: @other_label)

    ~H"""
    <div style="position:fixed;top:0;left:0;right:0;bottom:var(--jobpanel-h, 0px);z-index:60;background:rgba(0,0,0,0.45);display:flex;align-items:center;justify-content:center;padding:1rem">
      <form
        phx-submit="submit_report"
        phx-click-away="cancel_report"
        phx-window-keydown="cancel_report"
        phx-key="Escape"
        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;max-width:26rem;width:100%;box-shadow:0 10px 40px rgba(0,0,0,0.3)"
      >
        <div style="display:flex;align-items:center;justify-content:space-between;padding:0.85rem 1rem;border-bottom:1px solid var(--border)">
          <div style="font-size:0.95rem;font-weight:700;color:var(--text)">Report this answer</div>
          <button
            type="button"
            phx-click="cancel_report"
            aria-label="Close"
            style="background:none;border:none;font-size:1.1rem;cursor:pointer;color:var(--text-muted);line-height:1"
          >✕</button>
        </div>
        <div style="padding:0.85rem 1rem;display:flex;flex-direction:column;gap:0.45rem">
          <div style="font-size:0.78rem;color:var(--text-secondary)">
            What's wrong with it? A moderator will review your report.
          </div>
          <%= for {reason, i} <- Enum.with_index(@reasons ++ [@other]) do %>
            <label style="display:flex;align-items:center;gap:0.5rem;cursor:pointer;font-size:0.85rem;color:var(--text);padding:0.3rem 0.45rem;border:1px solid var(--border);border-radius:0.4rem;background:var(--bg-subtle)">
              <input type="radio" name="reason" value={reason} checked={i == 0} required />
              {reason}
            </label>
          <% end %>
          <input
            type="text"
            name="detail"
            maxlength="200"
            placeholder="Add a short note (optional)"
            autocomplete="off"
            style="margin-top:0.2rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.4rem;background:var(--bg-surface);color:var(--text);font-size:0.85rem;width:100%"
          />
        </div>
        <div style="display:flex;justify-content:flex-end;gap:0.5rem;padding:0.75rem 1rem;border-top:1px solid var(--border)">
          <button
            type="button"
            phx-click="cancel_report"
            style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.4rem 0.9rem;font-size:0.82rem;color:var(--text);cursor:pointer"
          >Cancel</button>
          <button
            type="submit"
            style="background:var(--danger,#c0392b);border:none;border-radius:0.4rem;padding:0.4rem 0.9rem;font-size:0.82rem;font-weight:600;color:#fff;cursor:pointer"
          >🚩 Report</button>
        </div>
      </form>
    </div>
    """
  end

  @doc """
  Builds the reason string stored on the flag from the modal's form params.
  A note replaces "Other" outright and is appended to a canned reason;
  result stays within the flag's 280-char limit.
  """
  def compose_reason(params) do
    reason = Map.get(params, "reason", @other_label)
    detail = params |> Map.get("detail", "") |> String.trim()

    cond do
      detail == "" -> reason
      reason == @other_label -> String.slice(detail, 0, 280)
      true -> String.slice("#{reason} — #{detail}", 0, 280)
    end
  end
end
