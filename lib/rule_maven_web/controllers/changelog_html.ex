defmodule RuleMavenWeb.ChangelogHTML do
  @moduledoc "The What's new page (ChangelogController)."
  use RuleMavenWeb, :html

  embed_templates "changelog_html/*"

  attr :release, Lccz.Changelog.Release, required: true

  @doc "One release's notes: everyone's bullets, then admins' (only non-empty for admins), collapsed."
  def notes(assigns) do
    ~H"""
    <ul :if={@release.everyone != []} class="changelog-list">
      <li :for={item <- @release.everyone}>{item}</li>
    </ul>
    <details :if={@release.admins != []} class="changelog-admins">
      <summary>For admins</summary>
      <ul class="changelog-list">
        <li :for={item <- @release.admins}>{item}</li>
      </ul>
    </details>
    """
  end

  attr :date, Date, default: nil

  def release_date(assigns) do
    ~H"""
    <time :if={@date} class="changelog-date" datetime={Date.to_iso8601(@date)}>
      {Calendar.strftime(@date, "%B %-d, %Y")}
    </time>
    """
  end
end
