defmodule RuleMavenWeb.GroupLive.Index do
  @moduledoc """
  "My groups" — lists the groups the current user belongs to and offers a
  form to create a new one. Each row links into `GroupLive.Show` via the
  group's opaque Hashid token (never the raw id).
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.Groups

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "My groups", form: to_form(%{"name" => ""}, as: :group))
     |> load_groups()}
  end

  def handle_event("create", %{"group" => %{"name" => name}}, socket) do
    case Groups.create_group(socket.assigns.current_user, %{name: name}) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created \"#{group.name}\".")
         |> assign(form: to_form(%{"name" => ""}, as: :group))
         |> load_groups()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :group))}
    end
  end

  defp load_groups(socket) do
    assign(socket, groups: Groups.list_for_user(socket.assigns.current_user))
  end

  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1rem">
      <h1 style="font-size:1.25rem;font-weight:800;margin:0 0 0.25rem 0">My groups</h1>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem 0">
        A group shares one answer feed and answer cache per game across its
        members — ask once, everyone at your table sees it. Share the invite
        link from a group's settings page to bring others in.
      </p>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Create a group</h2>
        <.form
          for={@form}
          id="new-group"
          phx-submit="create"
          style="display:flex;gap:0.5rem;flex-wrap:wrap;align-items:flex-start"
        >
          <div style="flex:1;min-width:12rem">
            <input
              type="text"
              name="group[name]"
              value={@form[:name].value}
              placeholder="e.g. Sunday Crew"
              maxlength="60"
              required
              style="width:100%;box-sizing:border-box;padding:0.5rem 0.7rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.9rem"
            />
            <div
              :for={{msg, _opts} <- @form[:name].errors || []}
              style="color:var(--red,#dc2626);font-size:0.75rem;margin-top:0.25rem"
            >
              {msg}
            </div>
          </div>
          <button type="submit" class="btn-primary btn-sm">Create group</button>
        </.form>
      </section>

      <section>
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Your groups</h2>
        <p :if={@groups == []} style="font-size:0.85rem;color:var(--text-muted);margin:0">
          You're not in any groups yet. Create one above, or ask a friend for
          their invite link.
        </p>
        <ul :if={@groups != []} style="list-style:none;margin:0;padding:0">
          <li
            :for={group <- @groups}
            style="border:1px solid var(--border);border-radius:0.75rem;background:var(--bg-surface);margin-bottom:0.6rem"
          >
            <.link
              navigate={~p"/groups/#{group}"}
              style="font-weight:700;text-decoration:none;color:var(--text);display:block;padding:0.8rem 1rem"
            >
              {group.name}
            </.link>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
