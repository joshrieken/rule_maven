defmodule RuleMaven.Security do
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Security.InjectionPattern

  # ── Pattern management ──────────────────────────────────────────────────────

  def list_patterns do
    Repo.all(from p in InjectionPattern, order_by: [asc: p.category, asc: p.pattern])
  end

  def get_pattern!(id), do: Repo.get!(InjectionPattern, id)

  def create_pattern(attrs) do
    %InjectionPattern{}
    |> InjectionPattern.changeset(attrs)
    |> Repo.insert()
  end

  def toggle_pattern(%InjectionPattern{} = p) do
    p
    |> InjectionPattern.changeset(%{enabled: !p.enabled})
    |> Repo.update()
  end

  def delete_pattern(%InjectionPattern{} = p), do: Repo.delete(p)

  def active_patterns do
    Repo.all(from p in InjectionPattern, where: p.enabled == true, select: p.pattern)
  end

  # ── Detection ───────────────────────────────────────────────────────────────

  def prompt_injection?(text) do
    normalized =
      text
      |> String.downcase()
      |> String.replace(~r/[\x00-\x1f\x7f​‌‍﻿]/u, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    patterns = active_patterns()
    Enum.any?(patterns, &String.contains?(normalized, &1))
  end

  # ── Blocked question management ─────────────────────────────────────────────

  def list_blocked_questions do
    alias RuleMaven.Games.QuestionLog

    Repo.all(
      from q in QuestionLog,
        where: q.blocked == true,
        order_by: [desc: q.inserted_at],
        preload: [:game, :user]
    )
  end

  def unblock_question(%RuleMaven.Games.QuestionLog{} = q) do
    q
    |> Ecto.Changeset.change(%{
      blocked: false,
      refused: false,
      answer: "Thinking..."
    })
    |> Repo.update()
  end
end
