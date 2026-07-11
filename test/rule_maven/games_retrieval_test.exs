defmodule RuleMaven.GamesRetrievalTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk

  defp published_doc(game, label, kind, full_text \\ "seed") do
    {:ok, d} =
      Games.create_document(%{
        game_id: game.id,
        label: label,
        kind: kind,
        full_text: full_text
      })

    {:ok, d} = Games.update_document(d, %{status: "published"})
    d
  end

  defp put_chunk(doc, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  defp sparse_vec(pairs) do
    Enum.reduce(pairs, List.duplicate(0.0, 768), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end

  test "returns source metadata with each chunk" do
    {:ok, game} = Games.create_game(%{name: "Meta #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Core rules", "rulebook")
    put_chunk(doc, "[Page 1]\ndraw five cards", List.duplicate(0.1, 768))

    [chunk] =
      Games.retrieve_chunks_for_games([game.id], "cards", embedding: List.duplicate(0.1, 768))

    assert %{
             content: "[Page 1]\ndraw five cards",
             label: "Core rules",
             kind: "rulebook",
             game_id: game_id,
             game_name: _,
             document_id: _
           } = chunk

    assert game_id == game.id
  end

  test "near-duplicate chunks collapse to the higher-authority source" do
    {:ok, game} = Games.create_game(%{name: "Dedup #{System.unique_integer([:positive])}"})
    rulebook = published_doc(game, "Rulebook", "rulebook")
    guide = published_doc(game, "Learn to play", "howto")
    vec = List.duplicate(0.1, 768)
    put_chunk(rulebook, "[Page 3]\nscoring: majority wins", vec)
    put_chunk(guide, "[Page 1]\nscoring: majority wins!", vec)

    chunks = Games.retrieve_chunks_for_games([game.id], "scoring", embedding: vec, limit: 6)

    assert Enum.count(chunks, &(&1.content =~ "majority wins")) == 1
    assert Enum.find(chunks, &(&1.content =~ "majority wins")).kind == "rulebook"
  end

  test "same kind: base game beats expansion on a duplicate" do
    {:ok, base} = Games.create_game(%{name: "Base #{System.unique_integer([:positive])}"})
    {:ok, exp} = Games.create_game(%{name: "Exp #{System.unique_integer([:positive])}"})
    :ok = Games.link_expansion(exp.id, base.id)
    vec = List.duplicate(0.1, 768)
    put_chunk(published_doc(base, "Base rules", "rulebook"), "[Page 2]\nsetup: shuffle deck", vec)
    put_chunk(published_doc(exp, "Exp rules", "rulebook"), "[Page 2]\nsetup: shuffle deck.", vec)

    chunks =
      Games.retrieve_chunks_for_games([base.id, exp.id], "setup",
        embedding: vec,
        base_game_id: base.id,
        limit: 6
      )

    kept = Enum.filter(chunks, &(&1.content =~ "shuffle deck"))
    assert [%{game_id: kept_game}] = kept
    assert kept_game == base.id
  end

  test "a chunk that collides with more than one already-kept chunk collapses the whole cluster" do
    {:ok, game} = Games.create_game(%{name: "Collision #{System.unique_integer([:positive])}"})
    # Authority order (low->high rank number = higher authority): errata(0) <
    # ... < notes(6) < other(7). Deliberately make the FIRST-arriving match
    # (A/notes) NOT the most authoritative, and the true best (D/errata)
    # arrive in the middle of the cluster, so a naive "only adjudicate the
    # first match" implementation picks the wrong winner and silently drops
    # the actually-best chunk instead of just re-ranking it away.
    notes = published_doc(game, "Notes", "notes")
    reference = published_doc(game, "Reference", "reference")
    errata = published_doc(game, "Errata", "errata")
    other = published_doc(game, "Other", "other")

    # A, B, D are each >=0.97 cosine-similar to J (the "incoming" chunk) but
    # pairwise below the threshold with each other (non-transitive similarity),
    # so all three land in `kept` independently before J arrives and matches
    # all of them at once.
    sin = :math.sqrt(1 - 0.98 * 0.98)
    a_vec = sparse_vec([{0, 0.98}, {1, sin}])
    b_vec = sparse_vec([{0, 0.98}, {2, sin}])
    d_vec = sparse_vec([{0, 0.98}, {3, sin}])
    j_vec = sparse_vec([{0, 1.0}])
    # Query embedding: closest to A/B/D (tied), farthest from J, so retrieval
    # order is A, B, D, then J last — reproducing the collision scenario.
    query_vec = sparse_vec([{1, 1.0}, {2, 1.0}, {3, 1.0}])

    put_chunk(notes, "[Page 1]\ncollide content A", a_vec)
    put_chunk(reference, "[Page 1]\ncollide content B", b_vec)
    put_chunk(errata, "[Page 1]\ncollide content D", d_vec)
    put_chunk(other, "[Page 1]\ncollide content J", j_vec)

    chunks =
      Games.retrieve_chunks_for_games([game.id], "collide", embedding: query_vec, limit: 6)

    # Nothing silently vanishes: 3 kept chunks collided with the 4th, so
    # exactly 1 survivor remains (kept-before(3) - matches(3) + 1 = 1), and
    # it's the highest-authority kind across the WHOLE cluster (errata) — not
    # just the winner of a 2-way compare against whichever match happened to
    # be first in the list.
    assert length(chunks) == 1
    assert hd(chunks).kind == "errata"
  end

  test "a top-ranked duplicate cluster's survivor stays first and isn't dropped by take(limit)" do
    {:ok, game} = Games.create_game(%{name: "Ordering #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Rulebook", "rulebook")

    # c1 and c5 are near-duplicates (cosine sim 0.9801 >= threshold); c2, c3, c4
    # are distinct and don't collide with anything. Relevance order (via the
    # query vector below) is c1, c2, c3, c4, c5 — so by the time c5 arrives and
    # collides with c1, TWO non-colliding chunks (c2, c3... actually c2,c3,c4)
    # sit between them in `kept`. The buggy `rest ++ [winner]` appends the
    # survivor to the END of kept ([c2,c3,c4,winner]); with limit: 3,
    # Enum.take(3) then silently drops the survivor entirely, even though it
    # was the single most-relevant chunk retrieved.
    mag = 0.99
    sin = :math.sqrt(1 - mag * mag)
    c1_vec = sparse_vec([{0, mag}, {10, sin}])
    c5_vec = sparse_vec([{0, mag}, {11, sin}])
    c2_vec = sparse_vec([{20, 1.0}])
    c3_vec = sparse_vec([{21, 1.0}])
    c4_vec = sparse_vec([{22, 1.0}])

    put_chunk(doc, "[Page 1]\ntop dup A", c1_vec)
    put_chunk(doc, "[Page 2]\nmiddle content two", c2_vec)
    put_chunk(doc, "[Page 3]\nmiddle content three", c3_vec)
    put_chunk(doc, "[Page 4]\nmiddle content four", c4_vec)
    put_chunk(doc, "[Page 5]\ntop dup B", c5_vec)

    # Query weighted so relevance order is exactly c1, c2, c3, c4, c5.
    query_vec = sparse_vec([{0, 0.5}, {10, 5.0}, {20, 0.9}, {21, 0.8}, {22, 0.7}])

    chunks =
      Games.retrieve_chunks_for_games([game.id], "anything", embedding: query_vec, limit: 3)

    assert length(chunks) == 3
    assert hd(chunks).content =~ "top dup"
    assert Enum.any?(chunks, &(&1.content =~ "middle content two"))
    assert Enum.any?(chunks, &(&1.content =~ "middle content three"))
  end

  test "a lexically strong but vector-distant chunk is rescued into the results" do
    {:ok, game} = Games.create_game(%{name: "Hybrid #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Rulebook", "rulebook")

    query_vec = sparse_vec([{0, 1.0}])
    # Three "noise" chunks each sit close to the query vector (cosine sim
    # 0.9 — closer than the lexical-match chunk below) but on distinct
    # sub-dimensions, so they don't collapse into each other as near-dupes;
    # none share any vocabulary with the question.
    put_chunk(doc, "[Page 1]\nunrelated filler wombat gazebo", sparse_vec([{0, 0.9}, {1, 0.436}]))
    put_chunk(doc, "[Page 2]\nanother filler paragraph zeppelin", sparse_vec([{0, 0.9}, {2, 0.436}]))
    put_chunk(doc, "[Page 3]\nyet more filler content lighthouse", sparse_vec([{0, 0.9}, {3, 0.436}]))

    # This chunk is embedded orthogonal to the query (cosine similarity 0),
    # so pure vector search ranks it dead last / outside the limit — but its
    # text is a near-exact lexical match for the question, which is exactly
    # the "5 hero tiles => max players" style inference case from prod.
    far_vec = sparse_vec([{50, 1.0}])
    put_chunk(doc, "[Page 4]\n5 hero tiles 5 hero standees", far_vec)

    chunks =
      Games.retrieve_chunks_for_games([game.id], "how many hero tiles hero standees",
        embedding: query_vec,
        limit: 3
      )

    assert length(chunks) == 3
    assert Enum.any?(chunks, &(&1.content =~ "hero tiles"))
  end

  # Prod regression (Horrified D&D): the one chunk answering the question was a
  # multi-topic mega-chunk whose embedding ranked 11th of 18 (outside top-10),
  # and its vocabulary ("location") differed from the question's ("space") so
  # the lexical rescue's overlap floor missed it too. With the corpus this
  # small, the boost must include everything.
  test "small_corpus_boost surfaces a chunk that top-k ranking and lexical rescue both miss" do
    {:ok, game} = Games.create_game(%{name: "Boost #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Rulebook", "rulebook")
    query_vec = sparse_vec([{0, 1.0}])

    for i <- 1..4 do
      put_chunk(doc, "[Page #{i}]\nnoise filler #{i} zeppelin", sparse_vec([{0, 0.9}, {i, 0.436}]))
    end

    # Vector-distant (cosine 0 to the query) AND only 2 question words overlap
    # ("move", "monster") — below the lexical rescue floor of 3.
    put_chunk(
      doc,
      "[Page 5]\nHeroes may move into or out of a location with a monster.",
      sparse_vec([{50, 1.0}])
    )

    question = "can I move through a space containing a monster"

    without =
      Games.retrieve_chunks_for_games([game.id], question, embedding: query_vec, limit: 3)

    refute Enum.any?(without, &(&1.content =~ "location with a monster"))

    with_boost =
      Games.retrieve_chunks_for_games([game.id], question,
        embedding: query_vec,
        limit: 3,
        small_corpus_boost: true
      )

    assert length(with_boost) == 5
    assert Enum.any?(with_boost, &(&1.content =~ "location with a monster"))
  end

  test "small_corpus_boost does not expand past the chunk-count cap" do
    {:ok, game} = Games.create_game(%{name: "BoostCap #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Rulebook", "rulebook")

    for i <- 1..26 do
      put_chunk(doc, "[Page 1]\nchunk number #{i}", sparse_vec([{i, 1.0}]))
    end

    chunks =
      Games.retrieve_chunks_for_games([game.id], "anything",
        embedding: sparse_vec([{1, 1.0}]),
        limit: 3,
        small_corpus_boost: true
      )

    assert length(chunks) == 3
  end

  test "small_corpus_boost does not expand past the char budget" do
    {:ok, game} = Games.create_game(%{name: "BoostChars #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Rulebook", "rulebook")
    big = String.duplicate("a", 35_000)

    put_chunk(doc, "[Page 1]\n#{big} alpha", sparse_vec([{1, 1.0}]))
    put_chunk(doc, "[Page 2]\n#{big} beta", sparse_vec([{2, 1.0}]))

    chunks =
      Games.retrieve_chunks_for_games([game.id], "anything",
        embedding: sparse_vec([{1, 1.0}]),
        limit: 1,
        small_corpus_boost: true
      )

    assert length(chunks) == 1
  end

  test "full-text fallback attributes one entry per published document, not a merged blob" do
    {:ok, game} = Games.create_game(%{name: "Fallback #{System.unique_integer([:positive])}"})
    _rulebook = published_doc(game, "Core rules", "rulebook", "RULEBOOK full text body here.")
    _faq = published_doc(game, "Rulings FAQ", "faq", "FAQ full text body distinct from rulebook.")

    chunks =
      Games.retrieve_chunks_for_games([game.id], "anything",
        embedding: List.duplicate(0.1, 768)
      )

    assert length(chunks) == 2

    rulebook_entry = Enum.find(chunks, &(&1.kind == "rulebook"))
    faq_entry = Enum.find(chunks, &(&1.kind == "faq"))

    assert rulebook_entry.label == "Core rules"
    assert rulebook_entry.content =~ "RULEBOOK full text body"
    refute rulebook_entry.content =~ "FAQ full text body"

    assert faq_entry.label == "Rulings FAQ"
    assert faq_entry.content =~ "FAQ full text body"
    refute faq_entry.content =~ "RULEBOOK full text body"
  end
end
