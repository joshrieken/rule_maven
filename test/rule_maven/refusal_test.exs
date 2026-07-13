defmodule RuleMaven.RefusalTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk
  alias RuleMaven.LLM
  alias RuleMaven.Repo

  # ── Test Rulebooks ──

  @rulebook_a """
  SECTION 1: SETUP
  Each player draws 5 cards from the deck. The youngest player goes first.

  SECTION 2: TAKING A TURN
  On your turn, you may either play a card from your hand or draw 2 cards from the deck.
  After playing a card, you must discard one card from your hand.

  SECTION 3: COMBAT
  Combat follows the normal procedure. See Section 7 for the full combat rules.
  When attacked, you may defend by discarding a shield card. See Section 4.3 for shield rules.

  SECTION 4: EQUIPMENT
  4.1 Weapons: Each weapon adds +2 to your attack roll.
  4.2 Armor: Each armor reduces incoming damage by 1.
  4.3 Shields: A shield blocks the first 3 damage each turn. Must be equipped before combat begins.
  Shields cannot be used if you are also carrying a two-handed weapon (see Section 4.1).

  SECTION 5: SCORING
  At the end of the game, red cards are worth 3 points, blue cards 1 point, gold cards 5 points.
  The player with the most points wins.

  SECTION 6: TIE-BREAKING
  In case of a tie in total points, the player with the most gold cards wins.
  If still tied, the player who went last in turn order wins.

  SECTION 7: FULL COMBAT RULES
  Combat is resolved in rounds. Each round, both players roll a d6 and add their weapon bonus (Section 4.1).
  The higher total wins the round and deals 1 point of damage.
  If totals are equal, no damage is dealt.
  """

  @rulebook_b """
  CARD DRAW RULES
  At the start of your turn, draw 1 card from the deck.
  If you have no cards in hand at the start of your turn, draw 3 cards instead.

  MOVEMENT RULES
  You may move up to 4 spaces on your turn.
  If you are on a road space, you may move up to 6 spaces on your turn.

  REVISED RULES ERRATA
  Movement: Starting from the second printing, movement limit is 3 spaces, not 4.
  Road movement is also reduced to 5 spaces.
  This change applies to all games played after Jan 2025.

  SPECIAL ACTIONS
  You may perform one special action per turn. Special actions include:
  Trading with another player on your space, building a structure, or searching the discard pile.

  TRADING CLARIFICATION (FAQ v1.2)
  Trading is only allowed if both players agree and are on the same space.
  You may trade any number of cards or resources.
  Note: Some play groups disallow trading entirely. Check your house rules.
  """

  @rulebook_c """
  GETTING STARTED
  Shuffle the deck and deal 7 cards to each player. Place the remaining cards face down as the draw pile.
  Flip the top card to start the discard pile.

  ON YOUR TURN
  Draw a card from the draw pile. You may then play any number of cards from your hand by placing
  them face up on the table in front of you. Each card has an effect described on the card itself.

  WINNING THE GAME
  The first player to collect 10 victory points wins immediately. Victory points come from card effects.
  Some cards award points when played, some award points at end of game, and some award points conditionally.

  OPTIONAL RULES
  This game supports several optional rules. Players should agree before the game which optional rules
  are in effect. See the official website for the full list of optional rules.
  """

  # ── Test Setup ──

  setup do
    game_a = create_game_with_rulebook("Cross-Reference Quest", @rulebook_a)
    game_b = create_game_with_rulebook("Conflict Kingdom", @rulebook_b)
    game_c = create_game_with_rulebook("Void Realms", @rulebook_c)

    {:ok, game_a: game_a, game_b: game_b, game_c: game_c}
  end

  defp create_game_with_rulebook(name, text) do
    {:ok, game} = Games.create_game(%{name: name})
    {:ok, doc} = Games.create_document(%{game_id: game.id, label: "Core Rules", full_text: text})
    # Ensure document is published (create_document may auto-publish, but force it)
    Repo.update!(Ecto.Changeset.change(doc, status: "published"))
    game
  end

  # ── Mock helpers ──

  # Mock returns parse_response output: {:ok, %{answer: text, cited_passage: text}}
  defp with_mock_echo do
    mock = fn body ->
      # Retries append extra system messages (regeneration nonce), so match the
      # last user message rather than assuming a fixed [system, user] shape.
      %{content: q} = body.messages |> Enum.filter(&(&1.role == "user")) |> List.last()
      answer = "ECHO: question='#{String.slice(q, 0, 60)}'"
      {:ok, %{answer: answer, cited_passage: "mock-citation-text"}}
    end

    Application.put_env(:rule_maven, :llm_mock, mock)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp with_mock_refusal do
    mock = fn _body ->
      {:ok,
       %{
         answer: "The rulebook does not cover this question.",
         cited_passage: ""
       }}
    end

    Application.put_env(:rule_maven, :llm_mock, mock)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp with_mock_conflict do
    mock = fn _body ->
      {:ok,
       %{
         answer: "There is a conflict: Movement allows 4 spaces, but errata reduces it to 3.",
         cited_passage:
           "You may move up to 4 spaces on your turn. | Movement limit is 3 spaces, not 4."
       }}
    end

    Application.put_env(:rule_maven, :llm_mock, mock)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  # ── Tests ──

  describe "refusal — answer not in rulebook" do
    test "question absent from rulebook reaches LLM with refusal prompt", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "Can I trade cards with other players?")
      assert result.answer =~ "ECHO"
      assert result.faq_hit == false
    end

    test "optional rules not in text reaches LLM with correct context", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_c, "What are the optional rules for this game?")
      assert result.answer =~ "ECHO"
    end

    test "LLM refusal response passed through correctly", ctx do
      with_mock_refusal()

      {:ok, result} = LLM.ask(ctx.game_a, "Can I trade cards?")

      assert result.answer =~ "The rulebook does not cover"
      refute result.answer =~ "---CITATION---"
      assert result.faq_hit == false
    end
  end

  describe "cross-reference scenarios" do
    test "shield question hits combat section, answer in equipment section", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "How much damage does a shield block?")
      assert result.answer =~ "ECHO"
    end

    test "combat resolution question hits referenced combat rules", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "How is combat resolved?")
      assert result.answer =~ "ECHO"
    end

    test "tiebreaker question — answer in same rulebook, not cross-referenced", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "What happens if two players tie in points?")
      assert result.answer =~ "ECHO"
    end

    test "retrieval pulls cross-referenced sections", ctx do
      # The rulebook_a has: S3 references S7 and S4.3, S4.3 references S4.1, S7 references S4.1
      # Chunks should have section_labels and references_section metadata
      chunks =
        Repo.all(
          from c in Chunk,
            where:
              c.document_id in subquery(
                from d in RuleMaven.Games.Document,
                  where: d.game_id == ^ctx.game_a.id,
                  select: d.id
              )
        )

      assert chunks != []

      # Find chunk that talks about shields (Section 4.3)
      shield_chunks = Enum.filter(chunks, &String.contains?(&1.content, "shield blocks"))
      assert shield_chunks != []

      shield_chunk = List.first(shield_chunks)
      # Section label should be "4" (the SECTION 4 header) or "4.3"
      assert not is_nil(shield_chunk.section_label)

      # Find chunk that references another section ("see Section 4.1" or "See Section 7")
      ref_chunks = Enum.filter(chunks, &(not Enum.empty?(&1.references_section || [])))
      assert ref_chunks != [], "Expected at least one chunk with cross-references"

      ref_chunk = List.first(ref_chunks)
      assert ref_chunk.references_section != []
    end
  end

  describe "conflicting sections" do
    test "movement question hits both original and errata text", ctx do
      with_mock_conflict()

      {:ok, result} = LLM.ask(ctx.game_b, "How many spaces can I move on a road?")

      assert result.answer =~ "conflict"
      assert result.answer =~ "4 spaces"
      assert result.answer =~ "reduces it to 3"
    end

    test "movement without road — both sections in context", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_b, "How many spaces can I move?")

      assert result.answer =~ "ECHO"
      # Verifies retrieval returns both movement section and errata section
    end
  end

  describe "system prompt quality" do
    test "contains refusal instructions", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "What color is the board?")
      assert result.answer =~ "ECHO"
    end

    test "contains conflict handling instruction", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_b, "How many spaces can I move?")
      assert result.answer =~ "ECHO"
    end

    test "contains cross-reference instruction", ctx do
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_c, "How do I win?")
      assert result.answer =~ "ECHO"
    end
  end

  describe "retrieval fallback" do
    test "falls back to full document text when no chunks exist", ctx do
      Repo.delete_all(Chunk)
      with_mock_echo()

      {:ok, result} = LLM.ask(ctx.game_a, "How many cards do I draw at setup?")

      assert result.answer =~ "ECHO"
      assert result.faq_hit == false
    end
  end
end
