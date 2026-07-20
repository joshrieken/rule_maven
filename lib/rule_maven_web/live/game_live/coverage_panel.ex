defmodule RuleMavenWeb.GameLive.CoveragePanel do
  @moduledoc """
  Sidebar community coverage meter + "help fill the gaps" panel.

  Community accent = "us" (what the group has grounded). The personal title
  lives elsewhere (sub-bar); this panel is the shared corpus view. Inline
  styles match the surrounding `.question-sidebar` markup in `show.ex`.
  """
  use RuleMavenWeb, :html

  attr :for_game, :map, default: nil
  attr :gaps, :list, default: []
  attr :credit, :integer, default: 0

  def coverage_panel(assigns) do
    ~H"""
    <div
      :if={@for_game}
      class="coverage-panel"
      style="padding:0.5rem 0.75rem;border-bottom:1px solid var(--border)"
    >
      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:0.5rem">
        <span style="font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
          Rulebook coverage
        </span>
        <span style="font-size:0.72rem;font-weight:800;color:var(--text)">
          {pct_text(@for_game.pct)}
        </span>
      </div>

      <div
        role="progressbar"
        aria-label="Community rulebook coverage"
        style="margin-top:0.3rem;height:0.45rem;border-radius:9999px;background:color-mix(in srgb,var(--accent) 15%,transparent);overflow:hidden"
      >
        <div style={"height:100%;border-radius:9999px;background:var(--accent);width:#{bar_width(@for_game.pct)}"}>
        </div>
      </div>

      <p
        :if={@credit > 0}
        style="margin:0.35rem 0 0;font-size:0.66rem;color:var(--text-muted)"
      >
        You were first to ground {@credit} {pages_word(@credit)}
      </p>

      <details :if={@gaps != []} class="coverage-gaps" style="margin-top:0.4rem">
        <summary style="cursor:pointer;font-size:0.68rem;font-weight:700;color:var(--accent)">
          Help fill the gaps ({length(@gaps)})
        </summary>
        <ul style="list-style:none;margin:0.3rem 0 0;padding:0;max-height:11rem;overflow-y:auto">
          <li
            :for={g <- Enum.take(@gaps, 20)}
            style="display:flex;gap:0.4rem;padding:0.15rem 0;font-size:0.66rem;color:var(--text);min-width:0"
          >
            <span style="flex-shrink:0;font-weight:700;color:var(--text-muted)">p.{g.page}</span>
            <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
              {gap_text(g)}
            </span>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp gap_text(%{label: label, snippet: snippet}), do: label || snippet || "Untitled page"

  defp pct_text(nil), do: "—"
  defp pct_text(pct), do: "#{round(pct * 100)}%"

  defp bar_width(nil), do: "0%"
  defp bar_width(pct), do: "#{round(pct * 100)}%"

  defp pages_word(1), do: "page"
  defp pages_word(_), do: "pages"
end
