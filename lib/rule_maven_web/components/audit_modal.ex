defmodule RuleMavenWeb.AuditModal do
  @moduledoc """
  Admin-only per-question "audit trail": a small trigger button plus a
  page-level modal that tells the whole story of one question — facts and
  decision flags, the LLM-call process timeline, cost rollup, pool lineage
  (matched source + the later asks it served via cache), and community signals.

  Rendered as a PAGE-LEVEL modal (like ReportModal / the persona picker), NOT
  inline in a list row, for two reasons:

    * A stateful component can't repeat: a question tagged with two categories
      renders its card twice, which would collide on a live_component id.
    * On the Q&A page the modal must sit OUTSIDE the `position:fixed`
      `.chat-layout`, or that fixed ancestor becomes its containing block and
      clips it under the game header.

  Host wiring (each host already carries `@current_user`):

      # trigger, beside a rendered question (admin-only, renders nothing else):
      <AuditModal.audit_trigger current_user={@current_user} question_log_id={q.id} />

      # once, at the LiveView render root (outside any fixed panel):
      <AuditModal.audit_modal :if={@audit} audit={@audit} />

      # open/close, in the host's handle_event:
      def handle_event("open_audit", %{"id" => id}, socket),
        do: {:noreply, assign(socket, audit: AuditModal.fetch(id, socket.assigns.current_user))}
      def handle_event("close_audit", _p, socket),
        do: {:noreply, assign(socket, audit: nil)}

  Privacy: the LLM-call trace comes from `LLM.calls_for_question/1`, which scrubs
  a crew row's raw input/output (a bar admins are held to as well). Question text
  is shown raw for a solo row (admins already read it on /admin/questions) and
  withheld to the crew-safe text for a crew row — the same boundary the trace
  scrub draws (see `qtext/1`).
  """
  use Phoenix.Component

  alias RuleMaven.{Games, LLM, Users}
  alias RuleMaven.Games.QuestionLog

  @doc """
  Assemble everything the modal renders for `question_log_id`, or `nil` when the
  caller isn't an admin or the row is gone. Re-checks admin standing so a
  demoted admin's stale socket can't open it.
  """
  def fetch(question_log_id, current_user) do
    with true <- Users.can?(current_user, :admin),
         id when is_integer(id) <- to_int(question_log_id),
         %QuestionLog{} = row <- Games.get_question_log(id) do
      %{
        row: row,
        trace: LLM.calls_for_question(id),
        source: Games.pool_source(row),
        children: Games.pool_children(id)
      }
    else
      _ -> nil
    end
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      _ -> nil
    end
  end
  defp to_int(_), do: nil

  attr :current_user, :map, required: true
  attr :question_log_id, :any, required: true

  def audit_trigger(assigns) do
    ~H"""
    <button
      :if={Users.can?(@current_user, :admin)}
      type="button"
      phx-click="open_audit"
      phx-value-id={@question_log_id}
      title="Admin: full audit trail"
      style="display:inline-flex;align-items:center;gap:0.3rem;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.15rem 0.5rem;font-size:0.68rem;font-weight:600;color:var(--text-muted);cursor:pointer"
    >🔍 Audit trail</button>
    """
  end

  attr :audit, :map, required: true

  def audit_modal(assigns) do
    assigns =
      assigns
      |> assign(:row, assigns.audit.row)
      |> assign(:trace, assigns.audit.trace)
      |> assign(:source, assigns.audit.source)
      |> assign(:children, assigns.audit.children)

    ~H"""
    <div
      phx-click="close_audit"
      phx-window-keydown="close_audit"
      phx-key="Escape"
      style="position:fixed;top:0;left:0;right:0;bottom:var(--jobpanel-h, 0px);z-index:70;background:rgba(0,0,0,0.5);display:flex;align-items:center;justify-content:center;padding:1rem;box-sizing:border-box"
    >
      <div
        phx-click-away="close_audit"
        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.75rem;max-width:40rem;width:100%;max-height:calc(100% - 2rem);display:flex;flex-direction:column;box-shadow:0 10px 40px rgba(0,0,0,0.35);text-align:left"
      >
        <div style="flex:0 0 auto;display:flex;align-items:center;justify-content:space-between;padding:0.85rem 1rem;border-bottom:1px solid var(--border);background:var(--bg-surface);border-radius:0.75rem 0.75rem 0 0">
          <div style="font-size:0.95rem;font-weight:700;color:var(--text)">🔍 Question audit trail</div>
          <button
            type="button"
            phx-click="close_audit"
            aria-label="Close"
            style="background:none;border:none;font-size:1.1rem;cursor:pointer;color:var(--text-muted);line-height:1"
          >✕</button>
        </div>

        <div style="flex:1 1 auto;min-height:0;overflow-y:auto;padding:0.85rem 1rem;display:flex;flex-direction:column;gap:1rem">
          {facts(assigns)}
          {process(assigns)}
          {cost(assigns)}
          {lineage(assigns)}
          {signals(assigns)}
        </div>
      </div>
    </div>
    """
  end

  # ---- sections --------------------------------------------------------------

  defp facts(assigns) do
    ~H"""
    <section>
      {section_head("Facts")}
      <div style="font-size:0.78rem;color:var(--text);line-height:1.5">
        <div style="font-weight:600;margin-bottom:0.3rem;word-break:break-word">
          {qtext(@row)}
        </div>
        <dl style="display:grid;grid-template-columns:auto 1fr;gap:0.15rem 0.6rem;margin:0">
          {fact("Asked", fmt_dt(@row.inserted_at))}
          {fact("Row id", "##{@row.id}")}
          {fact("Visibility", @row.visibility)}
          {fact("Served", if(@row.pooled, do: "pool (cache hit)", else: "fresh generation"))}
          {fact("Normalized", yn(@row.question_normalized))}
          {fact("Verdict", @row.verdict || "—")}
          {fact("Model", @row.llm_model || "—")}
        </dl>
        <div style="display:flex;flex-wrap:wrap;gap:0.3rem;margin-top:0.5rem">
          {flag_chip("refused", @row.refused)}
          {flag_chip("blocked", @row.blocked)}
          {flag_chip("needs_review", @row.needs_review)}
          {flag_chip("stale", @row.stale)}
          <span :if={@row.error_kind} style={chip_style("var(--danger,#c0392b)")}>error: {@row.error_kind}</span>
        </div>
      </div>
    </section>
    """
  end

  defp process(assigns) do
    assigns = assign(assigns, :count, assigns.trace.totals.count)

    ~H"""
    <section>
      {section_head("Process — #{@count} LLM call(s)")}
      <%= if @count == 0 do %>
        <div style="font-size:0.78rem;color:var(--text-muted);background:var(--bg-subtle);border:1px dashed var(--border);border-radius:0.4rem;padding:0.6rem 0.75rem">
          <%= if @row.pooled do %>
            Served from the pool — no generation ran for this ask. See lineage below.
          <% else %>
            No LLM calls recorded — served from cache, or asked before call tracing existed.
          <% end %>
        </div>
      <% else %>
        <ol style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:0.4rem">
          <%= for {c, i} <- Enum.with_index(@trace.calls, 1) do %>
            <li style={"border:1px solid var(--border);border-left:3px solid #{if c.success, do: "var(--success,#16a34a)", else: "var(--danger,#c0392b)"};border-radius:0.4rem;padding:0.45rem 0.6rem;background:var(--bg-subtle)"}>
              <div style="display:flex;justify-content:space-between;gap:0.5rem;align-items:baseline">
                <span style="font-size:0.8rem;font-weight:700;color:var(--text)">{i}. {c.operation}</span>
                <span style="font-size:0.68rem;color:var(--text-muted);overflow-wrap:anywhere">{c.model}</span>
              </div>
              <div style="font-size:0.68rem;color:var(--text-muted);margin-top:0.2rem;display:flex;flex-wrap:wrap;gap:0.15rem 0.45rem;align-items:baseline">
                <span>{c.prompt_tokens || 0}→{c.completion_tokens || 0} tok</span>
                <span :if={c.detail["cached_tokens"]} title="provider-cached prompt tokens">⚡{c.detail["cached_tokens"]} cached</span>
                <span>{fmt_dur(c.duration_ms)}</span>
                <span>{fmt_usd(c.cost)}</span>
                <span :if={c.detail["reasoning_effort"]}>🧠 {c.detail["reasoning_effort"]}</span>
                <span
                  :if={c.detail["finish_reason"] not in [nil, "stop", "end_turn"]}
                  style="color:var(--warning,#d97706)"
                  title="model stopped before a natural end"
                >⚠ {c.detail["finish_reason"]}</span>
                <span :if={c.detail["truncation_retry"]} style="color:var(--warning,#d97706)" title="retry of a truncated call with a doubled token cap">↻ retry</span>
                <span :if={!c.success} style="color:var(--danger,#c0392b);font-weight:600">failed</span>
              </div>
              <div :if={!c.success && c.error_message} style="font-size:0.66rem;color:var(--danger,#c0392b);margin-top:0.2rem;overflow-wrap:anywhere">
                {String.slice(c.error_message, 0, 200)}
              </div>
              <details :if={c.detail["input"] || c.detail["output"]} style="margin-top:0.25rem">
                <summary style="cursor:pointer;opacity:0.8;font-size:0.64rem;color:var(--text-muted)">in / out</summary>
                <div :if={c.detail["input"]} style="margin-top:0.2rem">
                  <div style="font-size:0.62rem;font-weight:600;color:var(--text-secondary)">→ in</div>
                  <div style="font-size:0.64rem;color:var(--text-muted);white-space:pre-wrap;max-height:8rem;overflow:auto;overflow-wrap:anywhere;font-family:var(--font-mono,monospace)">{String.slice(to_string(c.detail["input"]), 0, 1200)}</div>
                </div>
                <div :if={c.detail["output"]} style="margin-top:0.3rem">
                  <div style="font-size:0.62rem;font-weight:600;color:var(--text-secondary)">← out</div>
                  <div style="font-size:0.64rem;color:var(--text-muted);white-space:pre-wrap;max-height:8rem;overflow:auto;overflow-wrap:anywhere;font-family:var(--font-mono,monospace)">{String.slice(to_string(c.detail["output"]), 0, 1200)}</div>
                </div>
              </details>
            </li>
          <% end %>
        </ol>
      <% end %>
    </section>
    """
  end

  defp cost(assigns) do
    assigns = assign(assigns, :totals, assigns.trace.totals)

    ~H"""
    <section>
      {section_head("Cost")}
      <div style="font-size:0.8rem;color:var(--text);display:flex;flex-direction:column;gap:0.15rem">
        <div style="display:flex;justify-content:space-between">
          <span style="color:var(--text-muted)">Total generation cost</span>
          <span style="font-weight:700">{fmt_usd(@totals.cost)}</span>
        </div>
        <div style="display:flex;justify-content:space-between;font-size:0.72rem;color:var(--text-muted)">
          <span>Tokens</span><span>{@totals.tokens}</span>
        </div>
        <div style="display:flex;justify-content:space-between;font-size:0.72rem;color:var(--text-muted)">
          <span>Wall time</span><span>{fmt_dur(@totals.duration_ms)}</span>
        </div>
        <div :if={@row.pooled} style="margin-top:0.3rem;font-size:0.72rem;color:var(--accent-ink,var(--accent));font-weight:600">
          Cache hit — this ask cost {fmt_usd(0.0)} to answer.
        </div>
      </div>
    </section>
    """
  end

  defp lineage(assigns) do
    ~H"""
    <section>
      {section_head("Pool lineage")}
      <div style="font-size:0.78rem;color:var(--text);display:flex;flex-direction:column;gap:0.5rem">
        <%= if @source do %>
          <div style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.5rem 0.6rem">
            <div style="font-size:0.66rem;text-transform:uppercase;letter-spacing:0.02em;color:var(--text-muted);font-weight:700;margin-bottom:0.2rem">Matched source (##{@source.id})</div>
            <div style="word-break:break-word">{qtext(@source)}</div>
          </div>
        <% else %>
          <div :if={@row.pooled} style="color:var(--text-muted)">
            Pooled, but the source row is no longer present.
          </div>
        <% end %>

        <div>
          <div style="font-size:0.66rem;text-transform:uppercase;letter-spacing:0.02em;color:var(--text-muted);font-weight:700;margin-bottom:0.25rem">
            Served {@children.count} later ask(s) via pool
          </div>
          <ul :if={@children.count > 0} style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:0.25rem">
            <%= for child <- @children.rows do %>
              <li style="font-size:0.74rem;color:var(--text-secondary);border-left:2px solid var(--border);padding-left:0.5rem;word-break:break-word">
                {qtext(child)}
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp signals(assigns) do
    ~H"""
    <section>
      {section_head("Community signals")}
      <div style="font-size:0.78rem;color:var(--text);display:flex;flex-wrap:wrap;gap:0.4rem 1rem">
        {fact_inline("Trust", fmt_float(@row.trust_score))}
        {fact_inline("Mismatches", @row.mismatch_count)}
        {fact_inline("Curated", yn(not is_nil(@row.canonical_answer)))}
        {fact_inline("Verified", yn(@row.verified))}
        {fact_inline("Favorited", yn(@row.favorited))}
      </div>
    </section>
    """
  end

  # ---- render helpers --------------------------------------------------------

  defp section_head(title) do
    assigns = %{title: title}

    ~H"""
    <div style="font-size:0.66rem;font-weight:800;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-muted);border-bottom:1px solid var(--border-subtle);padding-bottom:0.25rem;margin-bottom:0.45rem">
      {@title}
    </div>
    """
  end

  defp fact(label, value) do
    assigns = %{label: label, value: value}

    ~H"""
    <dt style="color:var(--text-muted)">{@label}</dt>
    <dd style="margin:0;color:var(--text);word-break:break-word">{@value}</dd>
    """
  end

  defp fact_inline(label, value) do
    assigns = %{label: label, value: value}

    ~H"""
    <span><span style="color:var(--text-muted)">{@label}:</span> {@value}</span>
    """
  end

  defp flag_chip(_label, false), do: nil
  defp flag_chip(_label, nil), do: nil

  defp flag_chip(label, true) do
    assigns = %{label: label}

    ~H"""
    <span style={chip_style("var(--warning,#b8860b)")}>{@label}</span>
    """
  end

  defp chip_style(color) do
    "font-size:0.64rem;font-weight:700;color:#{color};border:1px solid #{color};border-radius:0.35rem;padding:0.1rem 0.4rem"
  end

  # Question text for the audit. A solo row's raw wording is shown (admins
  # already read it on /admin/questions, and the audit's whole point is to see
  # what was asked). A CREW row is withheld to the crew-safe text — the same
  # boundary LLM.calls_for_question/1 draws on the raw call previews.
  defp qtext(%QuestionLog{} = q) do
    if QuestionLog.crew_origin?(q),
      do: QuestionLog.listed_question(q),
      else: QuestionLog.display_question(q)
  end

  defp yn(true), do: "yes"
  defp yn(_), do: "no"

  defp fmt_usd(nil), do: "$0.0000"
  defp fmt_usd(amt) when is_number(amt), do: "$" <> :erlang.float_to_binary(amt / 1, decimals: 4)

  defp fmt_float(nil), do: "0.0"
  defp fmt_float(f) when is_number(f), do: :erlang.float_to_binary(f / 1, decimals: 2)

  defp fmt_dur(nil), do: "—"
  defp fmt_dur(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp fmt_dur(ms) when is_number(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"

  defp fmt_dt(nil), do: "—"
  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp fmt_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp fmt_dt(other), do: to_string(other)
end
