defmodule RuleMavenWeb.GameLive.Prepare do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, Games, Readiness, LLM, Jobs}
  alias RuleMaven.Readiness.Estimator

  # Map a readiness step to the llm_logs operation name(s) whose logged spend
  # represents that step's actual cost. Steps absent here have no tracked spend.
  @step_operations %{
    extract: ["ocr_vision", "ocr_critic"],
    cleanup: ["cleanup"],
    embed: [],
    categories: ["categories"],
    cheat_sheet: ["cheat_sheet"],
    setup: ["setup"],
    did_you_know: ["did_you_know"],
    voices: ["voice"],
    theme: ["theme_palette"]
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Users.can?(socket.assigns.current_user, :admin) && Games.get_game_by_token(id)

    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(game) ->
        {:ok, socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      true ->
        Readiness.recompute(game)

        if connected?(socket) do
          Jobs.subscribe(Readiness.topic(game.id))
          Jobs.subscribe(Jobs.scope_topic("game", game.id))

          for d <- Games.list_documents(game) do
            Jobs.subscribe(Jobs.scope_topic("document", d.id))
          end
        end

        {:ok,
         socket
         |> assign(game: game, page_title: "Prepare — #{game.name}")
         |> load()}
    end
  end

  defp load(socket) do
    game = socket.assigns.game
    docs = Games.list_documents(game)
    steps = Readiness.state(game)
    by_operation = LLM.cost_by_operation_for_game(game.id)

    estimates =
      Map.new(steps, fn s -> {s.id, Estimator.step_cost(s.id, game, docs)} end)

    actuals =
      Map.new(steps, fn s -> {s.id, step_actual_cost(s.id, by_operation)} end)

    review_pages = Enum.sum(Enum.map(docs, &Games.review_page_count/1))

    assign(socket,
      steps: steps,
      playable?: Readiness.playable?(game),
      required_complete?: Readiness.required_complete?(game),
      publish_approved?: Readiness.publish_approved?(game.id),
      auto?: Readiness.auto?(game.id),
      pause_reason: Readiness.pause_reason(game.id),
      remaining_cost: Estimator.remaining_cost(game),
      rerun_cost: Estimator.rerun_cost(game),
      estimates: estimates,
      actuals: actuals,
      total_actual: LLM.cost_for_game(game.id),
      required_done: Enum.count(steps, &(&1.category == :required and &1.state == :done)),
      required_total: length(Readiness.required_steps()),
      review_pages: review_pages
    )
  end

  @impl true
  def handle_event("prepare", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.start_auto(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Preparing — running the pipeline…")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  def handle_event("approve_publish", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.approve_publish(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Published — the game is now ready.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  def handle_event("revoke_publish", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.revoke_publish(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Unpublished — the game is no longer ready.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  def handle_event("stop", _params, socket) do
    Readiness.stop_auto(socket.assigns.game.id)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, "Paused — the pipeline will stop after the current step.")}
  end

  @impl true
  def handle_info({:readiness, _game_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:job_run, _run}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket) do
    game = Games.get_game!(socket.assigns.game.id)

    socket
    |> assign(game: game)
    |> load()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/games/#{@game}/edit"} class="back-link">
        &larr; Back to {String.slice(@game.name, 0, 30)}
      </.link>

      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;margin:0.25rem 0 0.35rem">
        <h1 style="font-size:1.5rem;font-weight:700">Prepare {@game.name}</h1>
      </div>
      <p style="font-size:0.85rem;font-weight:600;margin:0 0 1rem;color:var(--text-muted)">
        <%= cond do %>
          <% @playable? -> %>
            <span style="color:var(--green)">✓ Ready</span>
          <% @required_complete? -> %>
            <span style="color:var(--yellow)">● Ready to publish — awaiting your approval</span>
          <% true -> %>
            Setting up… {@required_done}/{@required_total} required steps
        <% end %>
      </p>

      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(9rem,1fr));gap:0.6rem;margin-bottom:1rem">
        <.stat label="Remaining est. cost" value={"$#{fmt_cost(@remaining_cost)}"} />
        <.stat label="Actual cost so far" value={"$#{fmt_cost(@total_actual)}"} />
        <.stat label="Ready" value={if @playable?, do: "Yes", else: "No"} />
      </div>

      <div style="display:flex;align-items:center;gap:0.75rem;margin-bottom:1rem">
        <%= if @auto? do %>
          <span style="display:inline-flex;align-items:center;gap:0.4rem;font-size:0.85rem;font-weight:600;color:var(--accent)">
            <span style="display:inline-block;width:0.55rem;height:0.55rem;border-radius:50%;background:var(--accent)"></span>
            Running…
          </span>
          <button
            phx-click="stop"
            style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.4rem 1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:pointer"
          >
            Pause
          </button>
        <% else %>
          <%!-- Once the game is Ready, re-running the pipeline re-spends on
                enrichments, so deemphasize the action and confirm-gate it. --%>
          <button
            phx-click="prepare"
            data-confirm={
              @playable? &&
                "This game is already Ready. Re-run the pipeline (regenerates enrichments and spends)?"
            }
            style={
              if @playable?,
                do:
                  "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:pointer",
                else:
                  "background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:700;cursor:pointer"
            }
          >
            {if @playable?, do: "Re-run prepare", else: "Prepare game"} · est. ${fmt_cost(
              if @playable?, do: @rerun_cost, else: @remaining_cost
            )}
          </button>
        <% end %>

        <%!-- Manual publish gate: a fully-prepared game stays unpublished until
              an admin approves it here. --%>
        <button
          :if={@required_complete? && !@playable?}
          phx-click="approve_publish"
          style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:700;cursor:pointer"
        >
          ✓ Mark Ready
        </button>
        <button
          :if={@playable?}
          phx-click="revoke_publish"
          data-confirm="Unpublish this game? Users won't be able to ask questions until you re-publish."
          style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:600;cursor:pointer"
        >
          Unpublish
        </button>
      </div>

      <%= if @pause_reason && @pause_reason != "" do %>
        <div style="background:color-mix(in srgb,var(--yellow) 12%,var(--bg-surface));border:1px solid color-mix(in srgb,var(--yellow) 40%,var(--border));border-radius:0.5rem;padding:0.7rem 0.9rem;margin-bottom:1.25rem;font-size:0.82rem;color:var(--text)">
          {pause_message(assigns)}
        </div>
      <% end %>

      <h2 style="font-size:1rem;font-weight:700;margin:0 0 0.5rem">Pipeline</h2>
      <div style="border:1px solid var(--border);border-radius:0.5rem;overflow:hidden">
        <%= for step <- @steps do %>
          <.step_row
            step={step}
            estimate={Map.get(@estimates, step.id, 0.0)}
            actual={Map.get(@actuals, step.id)}
            action={step_action(step, @game)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :estimate, :float, required: true
  attr :actual, :any, required: true
  attr :action, :any, default: nil

  defp step_row(assigns) do
    ~H"""
    <div style={"display:flex;align-items:center;gap:0.75rem;padding:0.6rem 0.9rem;border-top:1px solid var(--border-subtle);#{if @step.state == :blocked, do: "opacity:0.62", else: ""}"}>
      <span style={"font-size:0.7rem;font-weight:700;padding:0.15rem 0.5rem;border-radius:1rem;white-space:nowrap;#{chip_style(@step.state)}"}>
        {chip_label(@step.state)}
      </span>
      <span style="flex:1;font-size:0.85rem;font-weight:600;color:var(--text)">
        {@step.label}
        <.link
          :if={@action}
          navigate={@action.href}
          style="font-size:0.72rem;font-weight:600;color:var(--accent);margin-left:0.4rem;white-space:nowrap"
        >
          {@action.label} &rarr;
        </.link>
      </span>
      <span style={"font-size:0.62rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;#{tag_style(@step.category)}"}>
        {if @step.category == :required, do: "Required", else: "Enrichment"}
      </span>
      <%= if @step.llm do %>
        <span style="font-size:0.72rem;color:var(--text-muted);min-width:5.5rem;text-align:right;white-space:nowrap">
          est. ${fmt_cost(@estimate)}
        </span>
        <span style="font-size:0.72rem;font-weight:600;color:var(--text);min-width:4.5rem;text-align:right;white-space:nowrap">
          {cost_or_dash(@actual)}
        </span>
      <% else %>
        <span style="min-width:5.5rem"></span>
        <span style="min-width:4.5rem;text-align:right;font-size:0.72rem;color:var(--text-muted)">
          —
        </span>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem">
      <div style="font-size:0.65rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);font-weight:700">
        {@label}
      </div>
      <div style="font-size:1.15rem;font-weight:700;color:var(--text);margin-top:0.15rem">
        {@value}
      </div>
    </div>
    """
  end

  # Contextual jump to where a human-action step is handled (source upload and
  # page review both live in the edit page's rulebook manager). Automated steps
  # return nil — the Prepare button drives those.
  defp step_action(%{state: :done}, _game), do: nil
  defp step_action(%{id: :source}, game), do: %{href: ~p"/games/#{game}/edit", label: "Upload"}
  defp step_action(%{id: :review}, game), do: %{href: ~p"/games/#{game}/edit", label: "Review"}
  defp step_action(_step, _game), do: nil

  defp pause_message(%{pause_reason: "needs_source"} = assigns) do
    ~H"""
    Upload a rulebook source first — <.link
      navigate={~p"/games/#{@game}/edit"}
      style="color:var(--accent);font-weight:600"
    >
      go to the edit page
    </.link>.
    """
  end

  defp pause_message(%{pause_reason: "needs_extract"} = assigns) do
    ~H"""
    Extraction incomplete — waiting on text extraction before the pipeline can continue.
    """
  end

  defp pause_message(%{pause_reason: "needs_review"} = assigns) do
    ~H"""
    {fmt_int(@review_pages)} low-confidence {ngettext("page needs", "pages need", @review_pages)} review — <.link
      navigate={~p"/games/#{@game}/edit"}
      style="color:var(--accent);font-weight:600"
    >
      review them on the edit page
    </.link>, then re-click Prepare to resume.
    """
  end

  defp pause_message(assigns), do: ~H""

  ## Cost helpers ------------------------------------------------------------

  # Sum the actual logged spend for a step from `cost_by_operation_for_game/1`
  # rows, or `nil` when the step has no tracked operations / no logged spend.
  defp step_actual_cost(step, by_operation) do
    case Map.get(@step_operations, step) do
      nil ->
        nil

      [] ->
        nil

      ops ->
        rows = Enum.filter(by_operation, &(&1.operation in ops))

        if rows == [] do
          nil
        else
          Enum.reduce(rows, 0.0, &(&1.cost + &2))
        end
    end
  end

  defp cost_or_dash(nil), do: "—"
  defp cost_or_dash(usd), do: "$#{fmt_cost(usd)}"

  defp fmt_cost(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)
  defp fmt_cost(_), do: "0.00"

  defp fmt_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp fmt_int(_), do: "0"

  ## Style helpers -----------------------------------------------------------

  defp chip_style(:done),
    do: "background:color-mix(in srgb,var(--green) 20%,var(--bg-surface));color:var(--green)"

  defp chip_style(:blocked),
    do: "background:var(--bg-subtle);color:var(--text-muted)"

  defp chip_style(_),
    do: "background:var(--bg-subtle);color:var(--text-secondary)"

  defp chip_label(:done), do: "Done"
  defp chip_label(:blocked), do: "Blocked"
  defp chip_label(_), do: "Pending"

  defp tag_style(:required), do: "color:var(--accent)"
  defp tag_style(_), do: "color:var(--text-muted)"
end
