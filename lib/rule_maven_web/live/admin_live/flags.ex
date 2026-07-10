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

  defp load_flags do
    Registry.all()
    |> Enum.map(fn f -> Map.put(f, :on?, Flags.enabled?(f.id, nil)) end)
    |> Enum.group_by(& &1.kind)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <h1>Feature Flags</h1>
      <p class="text-secondary">
        Boolean gate shown. Off means the feature vanishes for everyone (admins may still
        see it via a group override set on the console).
      </p>

      <%= for {kind, flags} <- @flags do %>
        <h2>{kind |> Atom.to_string() |> String.capitalize()}</h2>
        <ul class="flag-list">
          <%= for f <- flags do %>
            <li style="display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:0.5rem 0;border-bottom:1px solid var(--border)">
              <span>
                <strong>{f.label}</strong>
                <code class="text-muted">{f.id}</code>
              </span>
              <button
                type="button"
                class={["btn-sm", if(f.on?, do: "btn-primary", else: "btn-secondary")]}
                phx-click="toggle"
                phx-value-id={f.id}
              >
                {if f.on?, do: "On", else: "Off"}
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end
end
