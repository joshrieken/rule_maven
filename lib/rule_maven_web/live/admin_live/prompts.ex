defmodule RuleMavenWeb.AdminLive.Prompts do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      {:ok,
       assign(socket,
         page_title: "Prompts",
         saved: false,
         prompt_values:
           Map.new(RuleMaven.Prompts.specs(), &{&1.key, RuleMaven.Prompts.template(&1.key)})
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("reset_prompt", %{"key" => key}, socket) do
    Settings.delete("prompt_#{key}")

    {:noreply,
     assign(socket,
       prompt_values: Map.put(socket.assigns.prompt_values, key, RuleMaven.Prompts.default(key)),
       saved: false
     )}
  end

  @impl true
  def handle_event("save", params, socket) do
    # Prompt overrides: store only when the textarea differs from the code
    # default (so "Reset to default" / matching text falls back to the default).
    prompt_values =
      Map.new(RuleMaven.Prompts.specs(), fn %{key: key} ->
        val = params["prompt_#{key}"]
        default = RuleMaven.Prompts.default(key)

        cond do
          is_nil(val) ->
            {key, RuleMaven.Prompts.template(key)}

          normalize(val) == "" or normalize(val) == normalize(default) ->
            Settings.delete("prompt_#{key}")
            {key, default}

          true ->
            Settings.put("prompt_#{key}", val)
            {key, val}
        end
      end)

    {:noreply, assign(socket, prompt_values: prompt_values, saved: true)}
  end

  # Compare prompt text ignoring trailing whitespace / CRLF the browser may add,
  # so an unedited textarea round-trips as "same as default".
  defp normalize(nil), do: ""
  defp normalize(s), do: s |> String.replace("\r\n", "\n") |> String.trim_trailing()

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Admin</.link>
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">Prompts</h1>
      <p style="font-size:0.78rem;color:var(--text-muted);margin:0 0 1rem 0">
        Edit the LLM prompts. Placeholders like <code>{"{{game_name}}"}</code> are filled in
        at runtime — keep them. Leaving a prompt unchanged (or clicking Reset) uses the
        built-in default. Editing the Q&amp;A answer prompt's JSON schema can break answering.
      </p>

      <div :if={@saved} class="alert alert-info mb-4">
        Settings saved.
      </div>

      <form phx-submit="save" style="display:flex;flex-direction:column;gap:1rem">
        <%= for group <- RuleMaven.Prompts.groups() do %>
          <h2 style="font-size:0.82rem;font-weight:700;text-transform:uppercase;letter-spacing:0.03em;color:var(--text-muted);margin:0.5rem 0 -0.25rem 0;border-bottom:1px solid var(--border);padding-bottom:0.35rem">
            {group}
          </h2>
          <%= for %{key: key, label: label, description: desc, vars: vars} <- Enum.filter(RuleMaven.Prompts.specs(), &(&1.group == group)) do %>
            <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface)">
              <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;flex-wrap:wrap">
                <h2 style="font-size:0.9rem;font-weight:700;margin:0">{label}</h2>
                <button type="button" phx-click="reset_prompt" phx-value-key={key} class="btn-xs">
                  Reset to default
                </button>
              </div>
              <p style="font-size:0.72rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                {desc}
              </p>
              <p
                :if={vars != []}
                style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0"
              >
                Variables:
                <%= for v <- vars do %>
                  <code style="margin-right:0.4rem">{"{{#{v}}}"}</code>
                <% end %>
              </p>
              <textarea
                name={"prompt_#{key}"}
                rows="10"
                spellcheck="false"
                style="width:100%;margin-top:0.5rem;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.6rem;font-size:0.78rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;line-height:1.45;background:var(--bg);color:var(--text);resize:vertical"
              >{@prompt_values[key]}</textarea>
            </section>
          <% end %>
        <% end %>

        <button type="submit" class="btn-primary" style="align-self:flex-start">
          Save Settings
        </button>
      </form>
    </div>
    """
  end
end
