defmodule RuleMaven.Audit do
  @moduledoc """
  Append-only audit trail for sensitive admin/moderation actions. Feeds the
  `/admin/audit` browse page and gives moderation forensics (who did what, to
  whom, when) for the signals on the moderation dashboard.

  Logging is best-effort: a failure to record must never break the action being
  audited, so `log/3` rescues and warns rather than raising.
  """

  import Ecto.Query, warn: false
  require Logger

  alias RuleMaven.Repo
  alias RuleMaven.Audit.AuditLog

  # Cap on delete snapshots question_history/2 loads (newest-first). Served by
  # the partial expression index audit_logs_qdelete_game_idx.
  @history_cap 500

  @doc """
  Records an action. `actor` is the acting user (or nil for system actions),
  `action` a dotted verb like `"user.suspend"`. Opts:

    * `:target_type` / `:target_id` / `:target_label` — what was acted on
    * `:metadata` — extra context map

  Returns `:ok` regardless of outcome.
  """
  def log(actor, action, opts \\ []) do
    attrs = %{
      actor_id: actor && actor.id,
      actor_username: actor && actor.username,
      action: action,
      target_type: opts[:target_type],
      target_id: opts[:target_id],
      target_label: truncate(opts[:target_label]),
      metadata: opts[:metadata] || %{}
    }

    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.error("audit log failed: #{inspect(cs.errors)}")
    end

    :ok
  rescue
    e ->
      Logger.error("audit log crashed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Lists audit entries newest-first. Opts: `:action`, `:actor_id`,
  `:target_type`, `:target_id`, `:limit` (default 200), `:offset` (default 0)
  for paging into older history.
  """
  def list(opts \\ []) do
    limit = opts[:limit] || 200
    offset = opts[:offset] || 0

    AuditLog
    |> filter(:action, opts[:action])
    |> filter(:actor_id, opts[:actor_id])
    |> filter(:target_type, opts[:target_type])
    |> filter(:target_id, opts[:target_id])
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Prior deleted versions of a Q&A, newest first. `QuestionLog` rows carry no
  version link to what they replaced (regenerate/report/admin-delete all hard
  -delete the old row), so this is the only way to recover history.

  Question text is NOT stable across regenerations: a regenerate resubmits the
  *displayed* text (`canonical_question || cleaned_question || question`), so
  each generation's raw text can differ from the last. Instead of one exact
  match, this chain-walks: starting from the current row's texts (`seeds` — a
  string or list of raw/cleaned/canonical variants), it pulls in every delete
  snapshot sharing any text with the seed set, unions that snapshot's texts
  into the set, and repeats to a fixpoint. Admin-only surface.

  Bounded to the newest #{@history_cap} delete snapshots per game: the walk
  loads full metadata for every candidate row, so an unbounded fetch grows
  with the game's whole deletion history per history click. A chain long
  enough to have links past the cap loses its oldest versions — acceptable
  for a forensics view that renders newest-first anyway.
  """
  def question_history(game_id, seeds) do
    seeds =
      seeds
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    entries =
      from(l in AuditLog,
        where: l.action == "question.delete",
        where: l.target_type == "question",
        where: fragment("?->>'game_id' = ?", l.metadata, ^to_string(game_id)),
        order_by: [desc: l.inserted_at, desc: l.id],
        limit: @history_cap
      )
      |> Repo.all()

    matched_ids = chain_walk(entries, seeds, MapSet.new())
    Enum.filter(entries, &MapSet.member?(matched_ids, &1.id))
  end

  # Repeatedly sweep the entries, adopting any whose text variants intersect
  # the known set, until a full pass adds nothing.
  defp chain_walk(entries, known_texts, matched_ids) do
    {texts, ids, grew} =
      Enum.reduce(entries, {known_texts, matched_ids, false}, fn entry, {texts, ids, grew} ->
        entry_texts = entry_texts(entry)

        if not MapSet.member?(ids, entry.id) and
             not MapSet.disjoint?(entry_texts, texts) do
          {MapSet.union(texts, entry_texts), MapSet.put(ids, entry.id), true}
        else
          {texts, ids, grew}
        end
      end)

    if grew, do: chain_walk(entries, texts, ids), else: ids
  end

  defp entry_texts(entry) do
    ~w(question cleaned_question canonical_question)
    |> Enum.map(&entry.metadata[&1])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @doc "Distinct action verbs present in the log, for filter dropdowns."
  def actions do
    Repo.all(from l in AuditLog, distinct: true, select: l.action, order_by: l.action)
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, _field, ""), do: query
  defp filter(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  defp truncate(nil), do: nil
  defp truncate(s) when is_binary(s), do: String.slice(s, 0, 160)
  defp truncate(s), do: s |> to_string() |> String.slice(0, 160)
end
