defmodule RuleMaven.Faq do
  @moduledoc """
  FAQ context — CRUD, similarity search, draft generation, approval workflow.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Faq.FaqEntry
  alias RuleMaven.Faq.FaqCandidate
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

  # ── FAQ Candidates (review queue) ──

  def list_pending_candidates do
    Repo.all(
      from c in FaqCandidate,
        where: c.status == "pending",
        order_by: [desc: c.thumbs_down_count, desc: c.total_asked_count],
        preload: [:game]
    )
  end

  def list_pending_candidates(%RuleMaven.Games.Game{} = game) do
    Repo.all(
      from c in FaqCandidate,
        where: c.game_id == ^game.id and c.status == "pending",
        order_by: [desc: c.thumbs_down_count, desc: c.total_asked_count]
    )
  end

  def get_candidate!(id), do: Repo.get!(FaqCandidate, id)

  def upsert_candidate(attrs) do
    # Upsert by game_id + question_text to avoid duplicates from re-clustering
    existing =
      Repo.one(
        from c in FaqCandidate,
          where: c.game_id == ^attrs[:game_id] and c.question_text == ^attrs[:question_text]
      )

    if existing do
      existing
      |> FaqCandidate.changeset(attrs)
      |> Repo.update()
    else
      %FaqCandidate{}
      |> FaqCandidate.changeset(attrs)
      |> Repo.insert()
    end
  end

  def approve_candidate(%FaqCandidate{} = candidate, attrs \\ %{}) do
    answer = attrs[:answer] || candidate.sample_answer_text || ""

    # Create FAQ entry
    case create_faq(%{
           game_id: candidate.game_id,
           canonical_question: candidate.question_text,
           canonical_answer: answer,
           source_qa_ids: [],
           status: "published",
           auto_approved: false
         }) do
      {:ok, faq_entry} ->
        # Link candidate to published FAQ
        candidate
        |> FaqCandidate.changeset(%{status: "approved", published_faq_id: faq_entry.id})
        |> Repo.update()

        {:ok, faq_entry}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def reject_candidate(%FaqCandidate{} = candidate) do
    candidate
    |> FaqCandidate.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  @doc """
  Consolidates a question thread (root + followups) into a single FAQ entry.
  Takes a root QuestionLog, list of followup QuestionLogs, and optional overrides.
  """
  def consolidate_thread(root_question, followups, attrs \\ %{}) do
    canonical_question = attrs[:question] || root_question.question
    canonical_answer = attrs[:answer] || build_consolidated_answer(root_question, followups)
    source_ids = [root_question.id | Enum.map(followups, & &1.id)]

    question_embedding =
      case RuleMaven.Embed.embed(canonical_question) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    create_faq(%{
      game_id: root_question.game_id,
      canonical_question: canonical_question,
      canonical_answer: canonical_answer,
      question_embedding: question_embedding,
      source_qa_ids: source_ids,
      status: "published",
      auto_approved: false
    })
  end

  def build_consolidated_answer(root, followups) do
    parts = ["**Original:** #{root.answer}"]

    parts =
      if followups != [] do
        fu_text =
          followups
          |> Enum.map_join("\n\n", fn f -> "**Q: #{f.question}**\nA: #{f.answer}" end)

        parts ++ ["**Follow-ups:**\n#{fu_text}"]
      else
        parts
      end

    Enum.join(parts, "\n\n---\n\n")
  end
end
