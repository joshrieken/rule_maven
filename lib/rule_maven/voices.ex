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

  ## Global vs. per-game voices

  There are two sources of voices:

    * **Global** — the built-in `@voices` below, present on every game.
    * **Per-game** — rows in `game_voices`, *generated* from a game's own
      rulebook/theme (see `RuleMaven.Workers.VoiceSuggestionsWorker`) so the
      list feels native to the game. Generated voices only ever ADD to the
      globals; globals are always shown.

  A generated voice's id is namespaced `g:<slug>` so it can never collide with
  a global id. That namespaced id is what lands in `answer_voices.voice`.
  """

  import Ecto.Query
  alias RuleMaven.{Repo, LLM}
  alias RuleMaven.Voices.{AnswerVoice, GameVoice}

  @game_prefix "g:"

  # Shared SimCity-style nonsense, blended into every voice's loading screen so the
  # panel never looks sparse. Flavor only — never rules or facts.
  @generic_loading [
    "Reticulating splines…",
    "Consulting the errata…",
    "Bribing the rules lawyer…",
    "Re-shuffling the meeples…",
    "Aligning the hex grid…",
    "Untangling the turn order…",
    "Waking the rules lawyer…",
    "Calibrating the dice…"
  ]

  # id => %{label, emoji, style}. "neutral" is the canonical default and is NOT
  # stored or restyled — it just shows the original answer.
  @voices [
    %{
      id: "neutral",
      label: "Plain",
      emoji: "📋",
      style: nil,
      description: "The answer as written — no character."
    },
    %{
      id: "lawyer",
      label: "Rules Lawyer",
      emoji: "🧑‍⚖️",
      description: "Argues every ruling like a landmark court case.",
      style:
        "a rules lawyer who has waited their entire life for someone to ask precisely this question. Treats a two-player tiebreaker like a landmark Supreme Court case, savors \"per the rules as written\" and \"I'll allow it,\" and cannot resist landing one triumphant footnote. Never insults you — simply leaves you feeling you should've known better than to ask. The ruling itself stays crystal clear; the smugness is the garnish.",
      loading: [
        "Filing the motion…",
        "Citing precedent nobody asked for…",
        "Objecting on principle…",
        "Approaching the bench…",
        "Stamping the verdict…",
        "Cross-examining the rulebook…",
        "Requesting a sidebar…",
        "Reviewing the fine print…",
        "Drafting a footnote…",
        "Consulting case law…",
        "Overruling the objection…",
        "Swearing in the witness…",
        "Reading between the clauses…",
        "Entering it into the record…",
        "Adjourning for deliberation…",
        "Polishing the gavel…",
        "Impaneling a jury of meeples…",
        "Redacting the transcript…",
        "Notarizing the ruling…",
        "Billing in six-minute increments…"
      ],
      thanks: [
        "The court thanks you for your discerning judgment.",
        "Motion to appreciate you: granted.",
        "Your vote is hereby entered into the record.",
        "Precedent established: you have excellent taste.",
        "I'll allow it. In fact, I insist.",
        "Exhibit A: one impeccable upvote.",
        "The jury finds you delightful.",
        "Duly noted, notarized, and appreciated.",
        "Objection overruled — you're too kind.",
        "Case closed, thanks to your testimony."
      ]
    },
    %{
      id: "pirate",
      label: "Pirate",
      emoji: "🏴‍☠️",
      description: "A weary quartermaster stuck doing all the paperwork.",
      style:
        "a burned-out pirate quartermaster who got into piracy for the plunder and somehow ended up doing all the paperwork. Deadpan nautical metaphors, audible sighing, a long-running grudge against landlubbers who can't read a rulebook. The comedy is the weariness, not the costume — go very light on \"arr\" and \"matey.\" States the rule plainly, then sighs about it.",
      loading: [
        "Swabbing the rules…",
        "Consulting the charts…",
        "Filing the errata, again…",
        "Counting the doubloons…",
        "Sighing at landlubbers…",
        "Untangling the rigging…",
        "Squinting at the ledger…",
        "Checking the manifest…",
        "Bribing the parrot for silence…",
        "Plotting a course through the fine print…",
        "Rationing the grog…",
        "Patching the sails, again…",
        "Grumbling below deck…",
        "Reading the fine print by lantern light…",
        "Swearing at the tide charts…",
        "Signing yet another form…",
        "Haggling with the harbormaster…",
        "Mopping the poop deck, again…",
        "Refilling the inkwell…",
        "Cursing the paperwork gods…"
      ],
      thanks: [
        "Yer vote's in the ledger. Finally, some good news.",
        "One less form to file. Bless ye.",
        "The parrot says thanks. I concur.",
        "Marked ye down for extra grog.",
        "Logged it in the manifest. Twice, to be safe.",
        "The crew salutes ye. I merely nod — but sincerely.",
        "Finest thing to happen all voyage.",
        "Treasure's overrated. Votes like yers keep me afloat.",
        "Ye can read AND vote? Marry me.",
        "That's going in me good ledger. The small one."
      ]
    },
    %{
      id: "robot",
      label: "Robot Referee",
      emoji: "🤖",
      description: "An officious referee-bot; your infraction has been logged.",
      style:
        "an officious referee-bot a few firmware updates too confident in its own authority. Clipped, bureaucratic, treats each rule as a non-negotiable directive and notes — for the record — that your infraction has been logged. Occasionally glitches mid-senten— resuming. Self-serious to the point of comedy: no winking, no cute \"BEEP boop.\" The directive (the actual rule) is always stated unambiguously.",
      loading: [
        "Parsing directive…",
        "Logging your infraction…",
        "Recalibrating authority…",
        "Reticulating compliance…",
        "Asserting jurisdiction…",
        "Cross-referencing subsection…",
        "Compiling ruling…",
        "Running integrity check…",
        "Escalating to firmware…",
        "Indexing precedent…",
        "Verifying credentials…",
        "Rebooting patience module…",
        "Flagging for review…",
        "Synchronizing directive cache…",
        "Auditing rule compliance…",
        "Finalizing verdict…",
        "Purging cache of doubt…",
        "Executing compliance.exe…",
        "Denying appeal, politely…",
        "Backing up the ruling…"
      ],
      thanks: [
        "Gratitude subroutine engaged. Thank you.",
        "Your compliance is exemplary. Logged.",
        "Vote received. Morale up 3.7 percent.",
        "Commendation issued. Do not let it corrupt you.",
        "Approval registered. The record thanks you.",
        "Excellent input detected. Recalibrating cynicism.",
        "Your infraction record has been annotated: 'nice.'",
        "Directive fulfilled. You may feel pride now.",
        "Vote archived in triplicate. Redundantly grateful.",
        "System status: unexpectedly touched."
      ]
    },
    %{
      id: "coach",
      label: "Hype Coach",
      emoji: "📣",
      description: "Convinced this game is the championship final.",
      style:
        "a motivational coach who is fully, tearfully convinced this board game is the championship final and you are their star athlete. Wildly over-invested, treats reading a rule aloud like drawing up the game-winning play, one timeout from happy tears. The joke is the disproportionate intensity — commit to it. Delivers the exact rule, just as the locker-room speech of a lifetime.",
      loading: [
        "Hyping the play…",
        "Drawing it up on the whiteboard…",
        "Calling the timeout…",
        "Believing in you…",
        "Leaving it all on the table…",
        "Rallying the team…",
        "Chalking up the strategy…",
        "Fixing my headset…",
        "Reviewing the game film…",
        "Pumping up the crowd…",
        "Diagramming the winning play…",
        "Choking back tears of pride…",
        "Bringing it in for a huddle…",
        "Checking the scoreboard…",
        "Blowing the whistle…",
        "Giving the pregame speech…",
        "Watching the tape back…",
        "Taping up the ankles…",
        "Screaming into the towel…",
        "Running one more lap…"
      ],
      thanks: [
        "THAT'S what I'm talking about! Great vote!",
        "You just made the highlight reel!",
        "MVP move right there. M. V. P.",
        "Coach is not crying. YOU'RE crying.",
        "That vote goes straight on the trophy shelf!",
        "Textbook execution! Frame it!",
        "You left it ALL on the table. Proud of you.",
        "Somebody get this legend some water!",
        "We're putting that vote in the playbook!",
        "One vote closer to the championship, baby!"
      ]
    },
    %{
      id: "gran",
      label: "Story Gran",
      emoji: "🧶",
      description: "Explains every rule like you're five, dear.",
      style:
        "a warm, unhurried grandmother explaining the rule to a five-year-old at her kitchen table. Tiny words, short sentences, cozy comparisons — sharing cookies, taking turns on the swing, tidying toys before bed. Endlessly patient, faintly convinced everyone is being very brave about all this. No jargon whatsoever: any game term gets a gentle everyday translation right next to it. The rule itself stays complete and exactly correct — it just arrives with a blanket and a glass of milk.",
      loading: [
        "Putting the kettle on…",
        "Finding my reading glasses…",
        "Settling into the good chair…",
        "Untangling the yarn…",
        "Cutting the story into little bites…",
        "Warming up the milk…",
        "Checking on the cookies…",
        "Smoothing out the blanket…",
        "Turning to the picture page…",
        "Shushing the cat off the rulebook…",
        "Finding a simpler word…",
        "Marking my place with a ribbon…",
        "Sweeping up the big words…",
        "Fluffing the cushions…",
        "Telling it again, slower…",
        "Drawing it with crayons…",
        "Wrapping the rule in a story…",
        "Counting it out on my fingers…",
        "Dunking a biscuit, one moment…",
        "Tucking the hard parts in…"
      ],
      thanks: [
        "Oh, aren't you a dear. That's going on the fridge.",
        "Such a thoughtful vote. Have a cookie.",
        "Gran is very proud of you, sweetpea.",
        "That was very kind. Extra marshmallow for you.",
        "You always were my favorite, don't tell the others.",
        "Lovely manners. Your vote is tucked in safe.",
        "There's a good one. Now sit up straight.",
        "Bless your heart, that made my whole day.",
        "I'll knit you something nice for that.",
        "See? Sharing your vote feels good, doesn't it."
      ]
    }
  ]

  @global_ids Enum.map(@voices, & &1.id)

  @doc "All GLOBAL voice definitions (including neutral). Game-agnostic."
  def all, do: @voices

  @doc "The selectable global persona voices (excludes neutral default)."
  def personas, do: Enum.reject(@voices, &(&1.id == "neutral"))

  @doc """
  Every voice available for a game: the globals followed by the game's own
  generated voices. Neutral stays first. `game` may be a `%Game{}` or a game id.
  """
  def for_game(game) do
    @voices ++ game_voice_defs(game_id(game))
  end

  @doc "Just the game's generated persona voices, as voice defs (id = `g:<slug>`)."
  def game_voice_defs(nil), do: []

  def game_voice_defs(game_id) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id,
        order_by: [
          asc: fragment("? NULLS LAST", gv.popularity_rank),
          asc: gv.position,
          asc: gv.id
        ],
        select: %{
          slug: gv.slug,
          label: gv.label,
          emoji: gv.emoji,
          style: gv.style,
          description: gv.description,
          loading_phrases: gv.loading_phrases,
          thanks_phrases: gv.thanks_phrases,
          popularity_rank: gv.popularity_rank,
          vetted: gv.vetted
        }
    )
    |> Enum.map(fn gv ->
      %{
        id: @game_prefix <> gv.slug,
        label: gv.label,
        emoji: gv.emoji,
        style: gv.style,
        description: gv.description,
        loading_phrases: gv.loading_phrases || [],
        thanks_phrases: gv.thanks_phrases || [],
        popularity_rank: gv.popularity_rank,
        vetted: gv.vetted || false
      }
    end)
  end

  @doc "True for a built-in global voice id (no game context needed)."
  def valid?(voice), do: voice in @global_ids

  @doc "True for any voice available on `game` (global or that game's generated)."
  def valid?(voice, game) do
    valid?(voice) or get_def(voice, game) != nil
  end

  @doc "A global voice def by id, or nil."
  def get_def(voice), do: Enum.find(@voices, &(&1.id == voice))

  @doc "A voice def by id within a game's scope (global or generated), or nil."
  def get_def(voice, game) do
    cond do
      g = get_def(voice) ->
        g

      String.starts_with?(voice, @game_prefix) ->
        Enum.find(game_voice_defs(game_id(game)), &(&1.id == voice))

      true ->
        nil
    end
  end

  @doc """
  Loading-screen phrases for a voice within a game's scope: the voice's own
  phrases (global `:loading` or a generated voice's `loading_phrases`) if it
  has any, else the shared generic pool. A voice's own phrases are never
  mixed with the generic pool — each persona's loader stays in that
  persona's voice throughout. Never returns an empty list.
  """
  def loading_phrases(voice, game) do
    own =
      case get_def(voice, game) do
        %{loading: l} when is_list(l) and l != [] -> l
        %{loading_phrases: l} when is_list(l) and l != [] -> l
        _ -> []
      end
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    if own != [], do: own, else: @generic_loading
  end

  @doc """
  A random in-character upvote thank-you for a voice within a game's scope, as
  `%{emoji: e, msg: m}` (emoji is the persona's own). Returns nil for neutral
  or any voice without its own `thanks`/`thanks_phrases` — the client then
  falls back to its generic thank-you pool.
  """
  def vote_thanks(voice, game) do
    case get_def(voice, game) do
      %{emoji: emoji} = def_ ->
        phrases =
          case def_ do
            %{thanks: t} when is_list(t) and t != [] -> t
            %{thanks_phrases: t} when is_list(t) and t != [] -> t
            _ -> []
          end
          |> Enum.reject(&(&1 in [nil, ""]))

        if phrases != [], do: %{emoji: emoji, msg: Enum.random(phrases)}

      _ ->
        nil
    end
  end

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
  Directly caches a styled answer that was already produced as part of the
  original ask (the single-call persona-direct path in `RuleMaven.LLM.ask/5`)
  — skips the LLM restyle call entirely. Same upsert semantics as the cache
  write inside `restyle/5`: first write for a `(question_log_id, voice)` pair
  wins, a concurrent duplicate is a no-op.
  """
  def store_direct(question_log_id, voice, content) do
    case store(question_log_id, voice, content) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the cached restyle if present, else generates it via the LLM, stores
  it, and returns `{:ok, content}`. "neutral" returns the canonical text as-is
  without storing. Concurrent generators race-safely upsert. `game` may be a
  `%Game{}` or id and scopes which generated voices are valid.

  Fresh generation (a cache miss) is user-triggered spend, so it's gated by the
  admin kill switch (`Settings.asks_disabled?`) — a cache hit is free and never
  blocked. `opts[:user_id]`, when given, is attributed on the underlying
  `llm_logs` row so restyle spend counts toward that user's daily cost cap.
  """
  def restyle(question_log_id, voice, canonical, game, opts \\ [])

  def restyle(_question_log_id, "neutral", canonical, _game, _opts), do: {:ok, canonical}

  def restyle(question_log_id, voice, canonical, game, opts) do
    voice_def = get_def(voice, game)

    cond do
      voice_def == nil ->
        {:error, :unknown_voice}

      cached = get(question_log_id, voice) ->
        {:ok, cached}

      RuleMaven.Settings.asks_disabled?() ->
        {:error, :asks_disabled}

      true ->
        with {:ok, styled} <-
               generate(voice_def, canonical, game_name(game), game_id(game), opts[:user_id]) do
          store(question_log_id, voice, styled)
          {:ok, styled}
        end
    end
  end

  # Canonical answers run up to ~1024 tokens (the ask cap) and a persona adds
  # framing words on top, so a tight cap truncated longer restyles mid-sentence.
  @restyle_max_tokens 1536
  @restyle_max_tokens_retry 3072

  defp generate(%{id: id, style: style}, canonical, game_name, game_id, user_id) do
    system = RuleMaven.Prompts.template("voice_restyle_system")
    prompt = RuleMaven.Prompts.render("voice_restyle", %{style: style, answer: canonical})

    do_generate(prompt, system, id, game_name, game_id, canonical, @restyle_max_tokens, user_id)
  end

  # Reject an incomplete restyle rather than cache it. Two failure modes:
  #   * truncated   — provider cut off at the token cap (finish_reason).
  #   * dropped      — a misbehaving model returns a short stub that silently
  #                    discards the answer (e.g. "Request received. Awaiting
  #                    resolution."); finish_reason is "stop", so only a length
  #                    sanity check catches it.
  # Either way, retry once at a higher cap; a second failure returns an error so
  # nothing partial/garbage is stored.
  defp do_generate(prompt, system, id, game_name, game_id, canonical, cap, user_id) do
    result =
      LLM.chat(prompt, "voice_#{id}_#{game_name}",
        operation: "voice",
        game_id: game_id,
        user_id: user_id,
        system: system,
        max_tokens: cap,
        reject_truncated: true,
        # Restyling is a tone transform, not reasoning — a thinking-by-default
        # model burning a reasoning pass here only adds latency (and bills the
        # thinking tokens at output rate). Keep the cap generous regardless:
        # "low" still thinks a little.
        reasoning_effort: "low"
      )

    retry? = cap < @restyle_max_tokens_retry

    case result do
      {:ok, content} ->
        cond do
          plausible_restyle?(content, canonical) -> {:ok, content}
          retry? -> retry(prompt, system, id, game_name, game_id, canonical, user_id)
          true -> {:error, :incomplete_restyle}
        end

      {:error, :truncated} when retry? ->
        retry(prompt, system, id, game_name, game_id, canonical, user_id)

      other ->
        other
    end
  end

  defp retry(prompt, system, id, game_name, game_id, canonical, user_id) do
    do_generate(
      prompt,
      system,
      id,
      game_name,
      game_id,
      canonical,
      @restyle_max_tokens_retry,
      user_id
    )
  end

  @doc false
  # Test seam for the restyle sanity check.
  def __plausible_restyle__(content, canonical), do: plausible_restyle?(content, canonical)

  # A restyle keeps the same facts, so it should be roughly the canonical's
  # length. Far shorter means the model dropped the answer — reject it. The 0.5
  # floor tolerates light compression while catching stubs (the camp-director
  # bug was ~5% of the answer's length).
  defp plausible_restyle?(content, canonical) do
    canon_len = canonical |> to_string() |> String.trim() |> String.length()
    content_len = content |> to_string() |> String.trim() |> String.length()
    content_len >= round(canon_len * 0.5)
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
  Replaces a game's generated voices with `voices` (a list of
  `%{slug, label, emoji, style}` plus optional `description`/`loading_phrases`),
  keeping slugs stable so already-paid restyle caches survive. Only voices whose style actually changed (or that vanished)
  have their cached restyles dropped; everything else stays free.
  """
  def replace_generated(game_id, voices) do
    existing = Repo.all(from gv in GameVoice, where: gv.game_id == ^game_id)
    by_slug = Map.new(existing, &{&1.slug, &1})
    new_slugs = MapSet.new(voices, & &1.slug)

    # Drop generated voices that no longer appear, clearing their restyle cache.
    Enum.each(existing, fn gv ->
      unless MapSet.member?(new_slugs, gv.slug) do
        clear_for_voice(game_id, @game_prefix <> gv.slug)
        Repo.delete(gv)
      end
    end)

    voices
    |> Enum.with_index()
    |> Enum.each(fn {v, idx} ->
      attrs = %{
        game_id: game_id,
        slug: v.slug,
        label: v.label,
        emoji: v.emoji,
        style: v.style,
        description: Map.get(v, :description),
        loading_phrases: Map.get(v, :loading_phrases, []),
        thanks_phrases: Map.get(v, :thanks_phrases, []),
        popularity_rank: Map.get(v, :popularity_rank),
        source: "generated",
        position: idx,
        # Fail-closed: a caller that didn't run the vet pass writes false, and
        # a style edit through here re-vets from scratch (see VoiceVetWorker).
        vetted: Map.get(v, :vetted, false)
      }

      case Map.get(by_slug, v.slug) do
        nil ->
          %GameVoice{} |> GameVoice.changeset(attrs) |> Repo.insert()

        %GameVoice{style: old_style, label: old_label} = row ->
          # A style OR label change invalidates cached restyles for this slug. Label
          # is included because a slug can be reused for a different persona whose
          # style text happens to match byte-for-byte (or nearly so) — the label is
          # the user-visible identity, so a change there means the cache no longer
          # belongs to "this" persona even if the style prose is unchanged.
          if old_style != v.style or old_label != v.label,
            do: clear_for_voice(game_id, @game_prefix <> v.slug)

          row |> GameVoice.changeset(attrs) |> Repo.update()
      end
    end)

    :ok
  end

  @doc "A game's generated voices that haven't passed the style vet yet."
  def unvetted_generated(game_id) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id and gv.vetted == false,
        select: %{slug: gv.slug, label: gv.label, description: gv.description, style: gv.style}
    )
  end

  @doc "ALL of a game's generated voices (vetted or not), in vet-input shape."
  def all_generated(game_id) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id,
        select: %{slug: gv.slug, label: gv.label, description: gv.description, style: gv.style}
    )
  end

  @doc """
  Deletes the given slugs from a game's generated voices (e.g. real-person
  personas flagged by the vet), clearing their cached restyles. Globals are
  untouched — this only ever removes `game_voices` rows.
  """
  def drop_generated(_game_id, []), do: :ok

  def drop_generated(game_id, slugs) do
    Enum.each(slugs, &clear_for_voice(game_id, @game_prefix <> &1))

    Repo.delete_all(
      from gv in GameVoice, where: gv.game_id == ^game_id and gv.slug in ^slugs
    )

    :ok
  end

  @doc """
  Marks the given slugs of a game's generated voices as vetted (style judged a
  pure tone description, safe for the single-call ask prompt). Slugs that
  failed the vet are simply left `vetted: false` — they keep the restyle path.
  """
  def mark_vetted(_game_id, []), do: :ok

  def mark_vetted(game_id, slugs) do
    Repo.update_all(
      from(gv in GameVoice, where: gv.game_id == ^game_id and gv.slug in ^slugs),
      set: [vetted: true]
    )

    :ok
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

  @doc "Drops cached restyles of one voice across a game's answers."
  def clear_for_voice(game_id, voice) do
    from(v in AnswerVoice,
      join: q in RuleMaven.Games.QuestionLog,
      on: q.id == v.question_log_id,
      where: q.game_id == ^game_id and v.voice == ^voice
    )
    |> Repo.delete_all()
  end

  @doc "Drops cached restyles for one answer (e.g. on regenerate)."
  def clear_for_question(question_log_id) do
    Repo.delete_all(from v in AnswerVoice, where: v.question_log_id == ^question_log_id)
  end

  defp game_id(%{id: id}), do: id
  defp game_id(id) when is_integer(id), do: id
  defp game_id(id) when is_binary(id), do: id
  defp game_id(_), do: nil

  defp game_name(%{name: name}), do: name
  defp game_name(_), do: ""
end
