defmodule RuleMavenWeb.GroupLive.Join do
  @moduledoc """
  Join-by-invite-link landing page. `:code` is the group's invite code —
  a random secret, not a database id, so it belongs directly in the URL
  (unlike the group token used everywhere else).

  Joining is attempted once, at mount, against the acting user. Already
  being a member is treated as success (idempotent link-sharing). Every
  other failure renders a human-readable reason and a way back to
  `/groups` — this path must never crash on a stale, disabled, or
  outright forged code.
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.Groups

  # The join is a WRITE, so it must not run in the disconnected (static) render:
  # LiveView mounts twice, and doing it in both meant the connected mount always
  # came back `{:error, :already_member}` — a first-time joiner was told "you're
  # already in this group" — besides writing to the DB during an HTTP render.
  # Connected mount only; the static pass renders a neutral "Joining…".
  def mount(%{"code" => code}, _session, socket) do
    if connected?(socket) do
      {:ok, do_join(socket, code)}
    else
      {:ok, assign(socket, page_title: "Joining…", outcome: :pending, group: nil)}
    end
  end

  defp do_join(socket, code) do
    user = socket.assigns.current_user
    result = Groups.join_by_code(user, code)

    # One lookup for every branch. (On :invalid_code there is by definition no
    # group with this code, so this is nil — the template doesn't use it there.)
    group = Groups.get_group_by_code(code)

    case result do
      # `group` is a SEPARATE read issued after the join committed, so the owner
      # could have deleted the group in the window between them — a sub-ms
      # cross-user race, but reading `group.name` off nil would 500 the joiner into
      # a reconnect loop. A gone group falls through to the neutral error render.
      {:ok, _membership} when not is_nil(group) ->
        assign(socket, page_title: "Joined #{group.name}", outcome: :joined, group: group)

      {:error, :already_member} when not is_nil(group) ->
        assign(socket, page_title: group.name, outcome: :already_member, group: group)

      {:error, reason} when reason != :already_member ->
        assign(socket,
          page_title: "Can't join group",
          outcome: :error,
          reason: reason,
          group: group
        )

      # Joined (or already a member), but the group vanished before we could read
      # it back. Render the neutral "can't join" page rather than crash.
      _ ->
        assign(socket,
          page_title: "Can't join group",
          outcome: :error,
          reason: :invalid_code,
          group: nil
        )
    end
  end

  defp error_message(:invalid_code),
    do: "That invite link doesn't look valid — couldn't find a matching group."

  defp error_message(:inactive), do: "This group's invite link has been turned off."
  defp error_message(:full), do: "This group is full."
  defp error_message(other), do: "Couldn't join this group (#{other})."

  def render(assigns) do
    ~H"""
    <div style="max-width:32rem;margin:2.5rem auto;padding:1rem;text-align:center">
      <div :if={@outcome == :pending}>
        <h1 style="font-size:1.2rem;font-weight:800;margin:0 0 0.5rem 0">Joining…</h1>
      </div>

      <div :if={@outcome in [:joined, :already_member]}>
        <div style="font-size:2rem;margin-bottom:0.5rem">🎉</div>
        <h1 style="font-size:1.2rem;font-weight:800;margin:0 0 0.5rem 0">
          <%= if @outcome == :joined do %>
            You joined {@group.name}
          <% else %>
            You're already in {@group.name}
          <% end %>
        </h1>
        <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem 0">
          You'll see this group's shared feed on any game you both play — <strong>including questions asked before you joined</strong>. Everyone in the
          group can see what you ask in it.
        </p>
        <.link navigate={~p"/groups/#{@group}"} class="btn-primary btn-sm">
          Go to {@group.name}
        </.link>
      </div>

      <div :if={@outcome == :error}>
        <div style="font-size:2rem;margin-bottom:0.5rem">🚫</div>
        <h1 style="font-size:1.2rem;font-weight:800;margin:0 0 0.5rem 0">Can't join this group</h1>
        <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem 0">
          {error_message(@reason)}
        </p>
        <.link navigate={~p"/groups"} class="btn-primary btn-sm">Back to Groups</.link>
      </div>
    </div>
    """
  end
end
