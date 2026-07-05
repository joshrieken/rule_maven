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
  -delete the old row), so this is the only way to recover history — matched
  by exact game + question text, the two stable things a regenerate keeps
  unchanged. Admin-only surface.
  """
  def question_history(game_id, question_text) do
    from(l in AuditLog,
      where: l.action == "question.delete",
      where: l.target_type == "question",
      where: fragment("?->>'game_id' = ?", l.metadata, ^to_string(game_id)),
      where: fragment("?->>'question' = ?", l.metadata, ^question_text),
      order_by: [desc: l.inserted_at, desc: l.id]
    )
    |> Repo.all()
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
