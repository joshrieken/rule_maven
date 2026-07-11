defmodule RuleMaven.Faq do
  @moduledoc """
  Community Q&A — counts and stats for admin-promoted QuestionLog entries.
  FaqEntry/FaqCandidate tables removed; community visibility lives on QuestionLog.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  # Counts everything browsable on the Community Q&A page: promoted community
  # rows plus unverified pooled rows (same filters as
  # Games.unverified_pool_questions/2), so the entry links appear whenever the
  # page has content.
  def community_count(%RuleMaven.Games.Game{} = game) do
    Repo.aggregate(
      from(q in QuestionLog,
        where:
          q.game_id == ^game.id and q.refused == false and
            (q.visibility == "community" or
               (q.pooled == true and q.browsable == true and q.needs_review == false and
                  q.blocked == false and q.stale == false and is_nil(q.error_kind) and
                  is_nil(q.pool_source_id) and q.trust_score > -1.0))
      ),
      :count
    )
  end

  def stats do
    community = Repo.aggregate(from(q in QuestionLog, where: q.visibility == "community"), :count)
    %{community: community || 0}
  end
end
