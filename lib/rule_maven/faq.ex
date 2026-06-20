defmodule RuleMaven.Faq do
  @moduledoc """
  FAQ context — CRUD, similarity search, draft generation, approval workflow.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Faq.FaqEntry
  alias RuleMaven.Repo

  # ── CRUD ──

  def list_faqs(%RuleMaven.Games.Game{} = game) do
    Repo.all(from f in FaqEntry, where: f.game_id == ^game.id)
  end

  def list_published(%RuleMaven.Games.Game{} = game) do
    Repo.all(from f in FaqEntry, where: f.game_id == ^game.id and f.status == "published")
  end

  def list_drafts(%RuleMaven.Games.Game{} = game) do
    Repo.all(from f in FaqEntry, where: f.game_id == ^game.id and f.status == "draft")
  end

  def get_faq!(id), do: Repo.get!(FaqEntry, id)

  def create_faq(attrs) do
    %FaqEntry{}
    |> FaqEntry.changeset(attrs)
    |> Repo.insert()
  end

  def update_faq(%FaqEntry{} = faq, attrs) do
    faq
    |> FaqEntry.changeset(attrs)
    |> Repo.update()
  end

  def approve_faq(%FaqEntry{} = faq, user_id) do
    update_faq(faq, %{
      status: "published",
      approved_by_id: user_id,
      approved_at: DateTime.utc_now(),
      auto_approved: false
    })
  end

  def discard_faq(%FaqEntry{} = faq) do
    update_faq(faq, %{status: "discarded"})
  end

  def delete_faq(%FaqEntry{} = faq), do: Repo.delete(faq)

  def faq_count(%RuleMaven.Games.Game{} = game) do
    Repo.aggregate(
      from(f in FaqEntry, where: f.game_id == ^game.id and f.status == "published"),
      :count
    )
  end

  # ── Draft creation from Q&A cluster ──

  @doc """
  Creates a FAQ draft from a cluster of question log entries.
  Returns {:ok, faq_entry} or {:error, changeset}.
  """
  def create_draft_from_cluster(game_id, question_logs, canonical_question, canonical_answer) do
    # Embed the canonical question
    question_embedding =
      case RuleMaven.Embed.embed(canonical_question) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    source_ids = Enum.map(question_logs, & &1.id)

    # Score for auto-approval
    score = cluster_score(question_logs)
    auto = score >= 4
    reason = auto_approve_reason(question_logs, score, auto)

    create_faq(%{
      game_id: game_id,
      canonical_question: canonical_question,
      canonical_answer: canonical_answer,
      question_embedding: question_embedding,
      source_qa_ids: source_ids,
      status: if(auto, do: "published", else: "draft"),
      auto_approved: auto,
      auto_approve_reason: reason
    })
  end

  defp cluster_score(question_logs) do
    score = 0

    # All have thumbs-up?
    all_up? = Enum.all?(question_logs, &(&1.feedback == "up"))
    score = if all_up?, do: score + 3, else: score

    # Cluster size
    count = length(question_logs)

    score =
      cond do
        count >= 3 -> score + 2
        count == 2 -> score + 1
        true -> score
      end

    # Different users?
    user_ids = Enum.map(question_logs, & &1.user_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)
    score = if length(user_ids) >= 2, do: score + 1, else: score

    score
  end

  defp auto_approve_reason(question_logs, score, auto) do
    if auto do
      count = length(question_logs)

      users =
        question_logs
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1)
        |> length()

      all_up = if Enum.all?(question_logs, &(&1.feedback == "up")), do: "all upvoted", else: ""
      "#{count} questions, #{users} users, #{all_up}, score=#{score}"
    else
      reasons =
        question_logs
        |> Enum.map(fn q ->
          cond do
            q.feedback == "down" -> "has downvote"
            q.feedback == nil -> "no feedback"
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      "score=#{score}, #{Enum.join(reasons, ", ")}"
    end
  end

  # ── Stats ──

  def stats do
    published = Repo.aggregate(from(f in FaqEntry, where: f.status == "published"), :count)
    drafts = Repo.aggregate(from(f in FaqEntry, where: f.status == "draft"), :count)

    %{published: published || 0, drafts: drafts || 0}
  end
end
