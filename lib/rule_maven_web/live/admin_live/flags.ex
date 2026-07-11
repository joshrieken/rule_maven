defmodule RuleMavenWeb.AdminLive.Flags do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Flags, Users, Audit}
  alias RuleMaven.Flags.Registry

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Feature Flags", flags: load_flags())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)
      on? = Flags.enabled?(flag, nil)

      if on?, do: Flags.disable(flag), else: Flags.enable(flag)

      Audit.log(
        socket.assigns.current_user,
        if(on?, do: "flag.disable", else: "flag.enable"),
        target_label: id
      )

      {:noreply,
       socket
       |> assign(flags: load_flags())
       |> put_flash(:info, "#{id} #{if on?, do: "disabled", else: "enabled"}.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("grant_actor", %{"_id" => id, "username" => username}, socket) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)

      case Users.get_user_by_username(String.trim(username)) do
        nil ->
          put_flash(socket, :error, "No user named #{username}.")

        user ->
          Flags.grant_actor(flag, user)
          Audit.log(socket.assigns.current_user, "flag.grant_actor", target_label: id)

          socket
          |> assign(flags: load_flags())
          |> put_flash(:info, "Granted #{id} to #{user.username}.")
      end
    end)
  end

  @impl true
  def handle_event("revoke_actor", %{"flag" => id, "user-id" => user_id}, socket) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)

      case Integer.parse(user_id) do
        {int, ""} ->
          case Users.get_user(int) do
            nil ->
              Flags.revoke_actor_id(flag, int)
              Audit.log(socket.assigns.current_user, "flag.revoke_actor", target_label: id)

              socket
              |> assign(flags: load_flags())
              |> put_flash(:info, "Revoked orphaned grant.")

            user ->
              Flags.revoke_actor(flag, user)
              Audit.log(socket.assigns.current_user, "flag.revoke_actor", target_label: id)

              socket
              |> assign(flags: load_flags())
              |> put_flash(:info, "Revoked #{id} from #{user.username}.")
          end

        _ ->
          socket
      end
    end)
  end

  @impl true
  def handle_event("set_percentage", %{"_id" => id, "percentage" => pct}, socket) do
    do_set_percentage(socket, id, pct)
  end

  @impl true
  def handle_event("set_percentage", %{"flag" => id, "percentage" => pct}, socket) do
    do_set_percentage(socket, id, pct)
  end

  defp do_set_percentage(socket, id, pct) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)

      case Integer.parse(pct) do
        {n, ""} when n in 0..99 ->
          Flags.set_percentage(flag, n / 100)

          Audit.log(socket.assigns.current_user, "flag.set_percentage",
            target_label: "#{id}=#{n}"
          )

          socket
          |> assign(flags: load_flags())
          |> put_flash(:info, "#{id} set to #{n}%.")

        _ ->
          put_flash(socket, :error, "Invalid percentage.")
      end
    end)
  end

  # Re-check admin capability on every event, then run fun/0 which returns a socket.
  defp with_admin(socket, fun) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:noreply, fun.()}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  defp load_flags do
    Registry.all()
    |> Enum.map(fn f ->
      f
      |> Map.put(:on?, Flags.enabled?(f.id, nil))
      |> Map.put(:gates, gate_view(f.id))
      |> Map.put(:counts, if(f.kind == :experiment, do: Flags.assignment_counts(f.id), else: nil))
    end)
    |> Enum.group_by(& &1.kind)
  end

  # Resolve actor targets ("user:<id>") back to usernames for display.
  defp gate_view(flag) do
    g = Flags.gates(flag)

    actors =
      Enum.map(g.actors, fn
        "user:" <> id ->
          case Integer.parse(id) do
            {int, _} -> %{id: int, username: username_for(int)}
            :error -> %{id: nil, username: id}
          end

        other ->
          %{id: nil, username: other}
      end)

    %{percentage: g.percentage, actors: actors}
  end

  defp username_for(user_id) do
    case Users.get_user(user_id) do
      %{username: name} -> name
      _ -> "user ##{user_id}"
    end
  end

  defp pct_value(%{gates: %{percentage: nil}}), do: nil
  defp pct_value(%{gates: %{percentage: r}}), do: round(r * 100)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <h1>Feature Flags</h1>
      <p class="text-secondary flag-intro">
        Boolean gate shown. Off means the feature vanishes for everyone (admins may still
        see it via a group override set on the console).
      </p>

      <section :for={{kind, flags} <- @flags} class="flag-section">
        <h2 class="flag-section__title">{kind |> Atom.to_string() |> String.capitalize()}</h2>

        <ul class="flag-list">
          <li :for={f <- flags} class="flag-row">
            <div class="flag-row__head">
              <span class="flag-row__name">
                <strong>{f.label}</strong>
                <code class="flag-row__code">{f.id}</code>
              </span>

              <button
                type="button"
                class={["btn-sm", if(f.on?, do: "btn-primary", else: "btn-secondary")]}
                phx-click="toggle"
                phx-value-id={f.id}
              >
                {if f.on?, do: "On", else: "Off"}
              </button>
            </div>

            <div class="flag-row__controls">
              <form id={"grant-#{f.id}"} phx-submit="grant_actor" class="flag-form">
                <input type="hidden" name="_id" value={f.id} />
                <input
                  type="text"
                  name="username"
                  placeholder="username"
                  aria-label={"Grant #{f.label} to a user"}
                />
                <button type="submit" class="btn-xs btn-outline">Grant</button>
              </form>

              <form id={"pct-#{f.id}"} phx-submit="set_percentage" class="flag-form">
                <input type="hidden" name="_id" value={f.id} />
                <input
                  type="number"
                  name="percentage"
                  min="1"
                  max="99"
                  value={pct_value(f)}
                  aria-label={"Rollout percentage for #{f.label}"}
                />
                <span>%</span>
                <button type="submit" class="btn-xs btn-outline">Set</button>
                <button
                  :if={f.gates.percentage != nil}
                  type="button"
                  class="btn-xs btn-secondary"
                  phx-click="set_percentage"
                  phx-value-flag={f.id}
                  phx-value-percentage="0"
                >
                  Clear
                </button>
              </form>
            </div>

            <div :if={f.gates.actors != []} class="flag-meta">
              <span>Granted to:</span>
              <span :for={a <- f.gates.actors} class="flag-grant">
                {a.username}
                <button
                  :if={a.id != nil}
                  type="button"
                  class="btn-xs btn-remove"
                  phx-click="revoke_actor"
                  phx-value-flag={f.id}
                  phx-value-user-id={a.id}
                  title={"Revoke #{a.username}"}
                >
                  ×
                </button>
              </span>
            </div>

            <div :if={f.counts} class="flag-meta">
              Assignments — control: {f.counts.control} · treatment: {f.counts.treatment}
            </div>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
