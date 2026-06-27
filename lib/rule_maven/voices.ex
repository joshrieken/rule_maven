defmodule RuleMaven.Voices do
  @moduledoc """
  Persona voices: cached, in-character restyles of canonical answers.

  The canonical answer (the pooled, citation-bearing source of truth) is never
  modified. A voice is a *rendering* of that prose — same facts, same numbers,
  different tone. Each `(answer, voice)` restyle is generated once and cached in
  `answer_voices`, so switching between voices is free after first touch and the
  cache is shared across every viewer.

  The restyler only ever sees the already-grounded answer text — never the
  rulebook — so it cannot introduce new rules. Citations, page numbers, and the
  verdict stamp render from the canonical row and are intentionally left neutral.
  """

  import Ecto.Query
  alias RuleMaven.{Repo, LLM}
  alias RuleMaven.Voices.AnswerVoice

  # id => %{label, emoji, style}. "neutral" is the canonical default and is NOT
  # stored or restyled — it just shows the original answer.
  @voices [
    %{id: "neutral", label: "Plain", emoji: "📋", style: nil},
    %{
      id: "lawyer",
      label: "Rules Lawyer",
      emoji: "🧑‍⚖️",
      style:
        "a smug, hyper-precise rules lawyer. Formal, lightly pedantic, fond of phrases like \"per the rules as written\" and \"strictly speaking.\" Never rude, just insufferably correct."
    },
    %{
      id: "pirate",
      label: "Pirate",
      emoji: "🏴‍☠️",
      style:
        "a swashbuckling pirate. Nautical slang, \"arr\", \"ye\", \"matey\", \"the rulebook be sayin'\". Playful and boisterous."
    },
    %{
      id: "robot",
      label: "Robot Referee",
      emoji: "🤖",
      style:
        "a deadpan robot referee. Terse, official, monotone. Clipped sentences. Occasional \"BEEP.\" or \"RULING:\" prefix. No emotion."
    },
    %{
      id: "coach",
      label: "Hype Coach",
      emoji: "📣",
      style:
        "an over-the-top motivational sports coach. Loud, encouraging, lots of energy and short pep-talk bursts. Still delivers the exact rule."
    }
  ]

  @voice_ids Enum.map(@voices, & &1.id)

  @doc "All voice definitions (including neutral)."
  def all, do: @voices

  @doc "The selectable persona voices (excludes neutral default)."
  def personas, do: Enum.reject(@voices, &(&1.id == "neutral"))

  def valid?(voice), do: voice in @voice_ids

  def get_def(voice), do: Enum.find(@voices, &(&1.id == voice))

  @doc "Cached restyle content for one (question, voice), or nil."
  def get(question_log_id, voice) do
    Repo.one(
      from v in AnswerVoice,
        where: v.question_log_id == ^question_log_id and v.voice == ^voice,
        select: v.content
    )
  end

  @doc "Map of `voice => content` already cached for a question."
  def cached_voices(question_log_id) do
    Repo.all(
      from v in AnswerVoice,
        where: v.question_log_id == ^question_log_id,
        select: {v.voice, v.content}
    )
    |> Map.new()
  end

  @doc """
  Returns the cached restyle if present, else generates it via the LLM, stores
  it, and returns `{:ok, content}`. "neutral" returns the canonical text as-is
  without storing. Concurrent generators race-safely upsert.
  """
  def restyle(_question_log_id, "neutral", canonical, _game_name), do: {:ok, canonical}

  def restyle(question_log_id, voice, canonical, game_name) do
    cond do
      not valid?(voice) ->
        {:error, :unknown_voice}

      cached = get(question_log_id, voice) ->
        {:ok, cached}

      true ->
        with {:ok, styled} <- generate(voice, canonical, game_name) do
          store(question_log_id, voice, styled)
          {:ok, styled}
        end
    end
  end

  defp generate(voice, canonical, game_name) do
    %{style: style} = get_def(voice)

    system =
      "You are a tone restyler. You rewrite a board-game rules answer in a different VOICE while keeping every fact, number, name, and rule EXACTLY the same. You must not add, remove, or change any rule or fact. You must not add new information or invent rules. Keep it roughly the same length. Preserve markdown (**bold**, lists). Output ONLY the rewritten answer, no preamble."

    prompt = """
    Rewrite the following answer in the voice of #{style}

    Keep all facts and numbers identical. Do not add rules. Do not add a sign-off unless it is one short in-character phrase.

    ANSWER:
    #{canonical}
    """

    LLM.chat(prompt, "voice_#{voice}_#{game_name}", system: system, max_tokens: 700)
  end

  defp store(question_log_id, voice, content) do
    %AnswerVoice{}
    |> AnswerVoice.changeset(%{
      question_log_id: question_log_id,
      voice: voice,
      content: content
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:question_log_id, :voice]
    )
  end

  @doc """
  Drops all cached restyles for a game's answers. Called when rulebook content
  changes (alongside pool invalidation) so stale-voiced answers regenerate.
  """
  def clear_for_game(game_id) do
    from(v in AnswerVoice,
      join: q in RuleMaven.Games.QuestionLog,
      on: q.id == v.question_log_id,
      where: q.game_id == ^game_id
    )
    |> Repo.delete_all()
  end

  @doc "Drops cached restyles for one answer (e.g. on regenerate)."
  def clear_for_question(question_log_id) do
    Repo.delete_all(from v in AnswerVoice, where: v.question_log_id == ^question_log_id)
  end
end
