defmodule RuleMaven.Jobs do
  @moduledoc """
  The unified background-job log. Every worker reports its lifecycle here —
  `start_run/4` when it begins, `event/4` for each progress line, `finish_run/3`
  at the end — and the admin DevTools-style panel (`RuleMavenWeb.AdminLive.JobPanel`)
  renders the result: a left rail of runs and a right pane of the selected run's
  event stream. This replaces the old per-feature `ingest_logs`/`reextract_logs`
  tables and the scattered ad-hoc progress logging.

  Two broadcast channels:

    * `admin_topic/0` (`"jobs"`) — the global feed the panel subscribes to. Gets
      every `{:job_run, run}` and `{:job_event, event}`.
    * `scope_topic/2` (`"job:<type>:<id>"`) — a per-subject feed page LiveViews
      can subscribe to so they react to a run's terminal state (e.g. reload a
      source once its cleanup finishes). Gets `{:job_run, run}` lifecycle only.

  All writes are best-effort: a logging failure must never break the job it is
  logging, so the write helpers rescue and degrade to a no-op (returning `nil`),
  and `event/4`/`finish_run/3` tolerate a `nil` run.
  """
  import Ecto.Query
  require Logger

  alias RuleMaven.Repo
  alias RuleMaven.Jobs.{JobRun, JobEvent}

  @admin_topic "jobs"

  # A run still `running` with no event for this long is presumed stranded by a
  # crash/restart (Oban's Lifeline re-runs the work under a fresh run); the
  # reconcile sweep marks the old row failed so the panel doesn't show a ghost.
  @stale_after_seconds 60 * 30

  @doc "PubSub topic for the global admin panel feed."
  def admin_topic, do: @admin_topic

  @doc "PubSub topic scoped to one subject (game/document/question)."
  def scope_topic(type, id) when not is_nil(id), do: "job:#{type}:#{id}"
  def scope_topic(_type, nil), do: nil

  @doc "Subscribe the calling process to a topic (admin feed or a scope feed)."
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, topic)
  end

  def subscribe(_), do: :ok

  ## Writes ------------------------------------------------------------------

  @doc """
  Open a job run. `scope` is `{type, id}` (e.g. `{"game", 12}`) or `nil` for a
  global job. Returns the inserted `JobRun`, or `nil` if the write failed (the
  caller can still pass that `nil` to `event/4`/`finish_run/3` safely).
  """
  def start_run(kind, scope, label \\ nil, opts \\ []) do
    {scope_type, scope_id} = normalize_scope(scope)
    now = DateTime.utc_now()

    run =
      %JobRun{}
      |> Ecto.Changeset.change(
        kind: to_string(kind),
        scope_type: scope_type,
        scope_id: scope_id,
        label: label,
        state: "running",
        oban_job_id: opts[:oban_job_id],
        started_at: now
      )
      |> Repo.insert!()

    broadcast_run(run)
    run
  rescue
    e ->
      Logger.debug("job start_run failed (#{kind}): #{inspect(e)}")
      nil
  end

  @doc "Append one progress line to a run. No-op when `run` is nil."
  def event(run, level, message, meta \\ %{})
  def event(nil, _level, _message, _meta), do: :ok

  def event(%JobRun{id: run_id}, level, message, meta) do
    event =
      %JobEvent{}
      |> Ecto.Changeset.change(
        job_run_id: run_id,
        level: to_string(level),
        message: to_string(message),
        meta: meta || %{}
      )
      |> Repo.insert!()

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, @admin_topic, {:job_event, event})
    :ok
  rescue
    e ->
      Logger.debug("job event failed (run #{run_id}): #{inspect(e)}")
      :ok
  end

  @doc """
  Close a run with a terminal `state` (`done` | `failed`) and an optional
  one-line summary. Broadcasts the terminal `{:job_run, run}` on both feeds so
  the panel and any subscribed page react. No-op when `run` is nil.
  """
  def finish_run(run, state, summary \\ nil)
  def finish_run(nil, _state, _summary), do: :ok

  def finish_run(%JobRun{} = run, state, summary) do
    finished_at = DateTime.utc_now()

    run =
      run
      |> Ecto.Changeset.change(
        state: to_string(state),
        summary: summary && String.slice(to_string(summary), 0, 500),
        finished_at: finished_at,
        cost_usd: run_cost(run, finished_at)
      )
      |> Repo.update!()

    broadcast_run(run)
    maybe_advance_readiness(run)
    :ok
  rescue
    e ->
      Logger.debug("job finish_run failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Closes still-`running` runs for a scope as `failed`.

  For crash cleanup: a worker that RAISES never reaches its own `finish_run/3`,
  so its run row sits `running` forever and the Jobs panel shows a job that never
  ends. The crashing worker usually no longer has the run struct in hand (the
  exception unwound past it), so this closes by scope instead.

  Pass `kind:` to restrict to one worker's runs — a scope is NOT unique to a
  worker (an ask and a voice restyle share `{"question", id}`), so an unscoped
  close would mark a healthy concurrent run failed. Omit it only when you really
  do mean every run for the scope.
  """
  def fail_running_runs(scope, summary, opts \\ [])

  def fail_running_runs({scope_type, scope_id}, summary, opts) when not is_nil(scope_id) do
    query =
      from r in JobRun,
        where:
          r.scope_type == ^to_string(scope_type) and r.scope_id == ^scope_id and
            r.state == "running"

    query =
      case opts[:kind] do
        nil -> query
        kind -> from r in query, where: r.kind == ^to_string(kind)
      end

    query
    |> Repo.all()
    |> Enum.each(&finish_run(&1, "failed", summary))

    :ok
  end

  def fail_running_runs(_scope, _summary, _opts), do: :ok

  # --- Readiness integration -------------------------------------------------
  #
  # A run's LLM/embedding spend, stamped onto the row so the admin log and the
  # Prepare page show per-step cost without recomputation. A pipeline step runs
  # in its own window for its own operation(s), so game + operation + time-window
  # attributes the spend cleanly. Unmapped kinds (no LLM, or untracked) → nil.
  @kind_operations %{
    "cleanup" => ["cleanup"],
    "categories" => ["categories"],
    "did_you_know" => ["did_you_know"],
    "setup_checklist" => ["setup"],
    "cheat_sheet" => ["cheat_sheet"],
    "voice" => ["voice"],
    "theme_palette" => ["theme_palette"],
    "download" => ["ocr_vision", "ocr_critic"],
    "reextract" => ["ocr_vision", "ocr_critic"],
    "ask" => ["ask"]
  }

  # Kinds whose completion should walk the auto "Prepare game" pipeline forward.
  @advance_kinds ~w(download extract cleanup embed)

  defp run_cost(%JobRun{started_at: nil}, _finished_at), do: nil

  defp run_cost(%JobRun{} = run, finished_at) do
    with ops when ops != [] <- Map.get(@kind_operations, run.kind, []),
         game_id when is_integer(game_id) <- run_game_id(run) do
      RuleMaven.LLM.cost_in_window(game_id, ops, run.started_at, finished_at)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_advance_readiness(%JobRun{kind: kind} = run) when kind in @advance_kinds do
    case run_game_id(run) do
      gid when is_integer(gid) -> RuleMaven.Readiness.advance(gid)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_advance_readiness(_run), do: :ok

  # Resolve the owning game id from a run's scope (game-scoped directly,
  # document-scoped via the document's game).
  defp run_game_id(%JobRun{scope_type: "game", scope_id: id}) when is_integer(id), do: id

  defp run_game_id(%JobRun{scope_type: "document", scope_id: id}) when is_integer(id) do
    Repo.one(from d in RuleMaven.Games.Document, where: d.id == ^id, select: d.game_id)
  end

  defp run_game_id(_run), do: nil

  defp broadcast_run(%JobRun{} = run) do
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, @admin_topic, {:job_run, run})

    case scope_topic(run.scope_type, run.scope_id) do
      nil -> :ok
      topic -> Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:job_run, run})
    end
  end

  defp normalize_scope({type, id}) when not is_nil(id), do: {to_string(type), id}
  defp normalize_scope(_), do: {"global", nil}

  ## Reads -------------------------------------------------------------------

  @doc """
  Recent runs for the panel's left rail, newest first. Opts: `:state`, `:kind`,
  `:scope_type` + `:scope_id`, `:limit` (default 100).
  """
  def list_runs(opts \\ []) do
    limit = opts[:limit] || 100

    JobRun
    |> filter_runs(opts)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_runs(query, opts) do
    Enum.reduce(opts, query, fn
      {:state, s}, q when is_binary(s) -> where(q, [r], r.state == ^s)
      {:kind, k}, q when is_binary(k) -> where(q, [r], r.kind == ^k)
      {:scope_type, t}, q when is_binary(t) -> where(q, [r], r.scope_type == ^t)
      {:scope_id, id}, q when not is_nil(id) -> where(q, [r], r.scope_id == ^id)
      _, q -> q
    end)
  end

  @doc "How many runs are currently `running` (left-rail badge)."
  def running_count do
    Repo.aggregate(from(r in JobRun, where: r.state == "running"), :count)
  end

  def get_run(id), do: Repo.get(JobRun, id)

  @doc "Event lines for a run, newest first (capped at the newest `limit`)."
  def events(run_id, limit \\ 1000) do
    from(e in JobEvent, where: e.job_run_id == ^run_id, order_by: [desc: e.id], limit: ^limit)
    |> Repo.all()
  end

  ## Maintenance -------------------------------------------------------------

  @doc "Delete job events (and the empty runs they belonged to) older than `cutoff`."
  def prune_events(%DateTime{} = cutoff) do
    {events_deleted, _} =
      from(e in JobEvent, where: e.inserted_at < ^cutoff) |> Repo.delete_all()

    # Drop finished runs older than the cutoff that no longer have any events.
    empty_old =
      from r in JobRun,
        as: :r,
        where: r.state != "running" and r.inserted_at < ^cutoff,
        where: not exists(from(e in JobEvent, where: e.job_run_id == parent_as(:r).id))

    {runs_deleted, _} = Repo.delete_all(empty_old)

    {events_deleted, runs_deleted}
  end

  @doc """
  Mark long-stuck `running` rows as failed. A run whose newest event (or, if it
  has none, whose `started_at`) is older than `@stale_after_seconds` is treated
  as stranded by a crash and closed so the panel stops showing a ghost job.
  """
  def reconcile_stale do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    last_event =
      from(e in JobEvent,
        group_by: e.job_run_id,
        select: %{run_id: e.job_run_id, at: max(e.inserted_at)}
      )

    stale =
      from(r in JobRun,
        left_join: le in subquery(last_event),
        on: le.run_id == r.id,
        where: r.state == "running",
        where: coalesce(le.at, r.started_at) < ^cutoff,
        select: r
      )
      |> Repo.all()

    Enum.each(stale, fn run ->
      finish_run(run, "failed", "Marked failed — no progress (server restart or crash).")
    end)

    length(stale)
  end
end
