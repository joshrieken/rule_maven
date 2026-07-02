defmodule RuleMaven.ReadinessTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Readiness, Repo, Settings}
  alias RuleMaven.Games.{Document, Chunk}
  alias RuleMaven.Readiness.Estimator

  import RuleMaven.GamesFixtures

  # Build a document with full control over its readiness signals.
  #   pages:   list of {confidence, cleaned?} — text is always present
  #   status:  document status
  #   embed:   :none | :pending | :done — chunk/embedding state
  defp doc_fixture(game, opts) do
    pages =
      opts
      |> Keyword.get(:pages, [])
      |> Enum.with_index()
      |> Enum.map(fn {{conf, cleaned?}, i} ->
        %{
          index: i,
          text: "raw page #{i}",
          cleaned: if(cleaned?, do: "clean page #{i}", else: nil),
          confidence: conf
        }
      end)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        label: "Rulebook",
        full_text: "Some rulebook text long enough to estimate.",
        game_id: game.id,
        status: Keyword.get(opts, :status, "published"),
        page_count: length(pages),
        pages: pages
      })
      |> Repo.insert()

    case Keyword.get(opts, :embed, :none) do
      :none ->
        :ok

      state ->
        vec = if state == :done, do: List.duplicate(0.0, 768), else: nil

        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          chunk_index: 0,
          content: "chunk",
          embedding: vec
        })
        |> Repo.insert!()
    end

    doc
  end

  describe "step_complete?/3" do
    test "source step needs at least one document" do
      game = game_fixture()
      refute Readiness.step_complete?(:source, game, [])

      doc_fixture(game, pages: [{0.9, true}])
      docs = Games.list_documents(game)
      assert Readiness.step_complete?(:source, game, docs)
    end

    test "review step fails while a low-confidence page is unreviewed" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}, {0.3, true}])
      docs = Games.list_documents(game)

      assert Readiness.step_complete?(:extract, game, docs)
      refute Readiness.step_complete?(:review, game, docs)
    end

    test "review step passes once all pages clear the confidence floor" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}, {0.8, true}])
      docs = Games.list_documents(game)
      assert Readiness.step_complete?(:review, game, docs)
    end

    test "review step is not vacuously done for an unextracted source" do
      game = game_fixture()
      # Saved but not yet extracted: no pages, so zero low-confidence pages. Review
      # must not read as done until extraction has produced text to review.
      doc_fixture(game, pages: [])
      docs = Games.list_documents(game)
      refute Readiness.step_complete?(:extract, game, docs)
      refute Readiness.step_complete?(:review, game, docs)
    end

    test "cleanup step needs every page cleaned" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}, {0.9, false}], status: "published")
      docs = Games.list_documents(game)
      refute Readiness.step_complete?(:cleanup, game, docs)
    end

    test "embed step needs chunks with no missing vectors" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}], embed: :pending)
      docs = Games.list_documents(game)
      refute Readiness.step_complete?(:embed, game, docs)

      game2 = game_fixture(name: "embedded", bgg_id: 101)
      doc_fixture(game2, pages: [{0.9, true}], embed: :done)
      assert Readiness.step_complete?(:embed, game2, Games.list_documents(game2))
    end

    test "embed step is not done while cleanup is pending, even with embedded chunks" do
      game = game_fixture()
      # Stale raw-text chunks embedded before cleanup ran must not read as done.
      doc_fixture(game, pages: [{0.9, false}], embed: :done)
      docs = Games.list_documents(game)
      refute Readiness.step_complete?(:embed, game, docs)
    end

    test "categories step is done from a draft cache or saved categories" do
      game = game_fixture()
      refute Readiness.step_complete?(:categories, game, [])

      # Unsaved draft in the Settings cache counts.
      Settings.put("categories_#{game.id}", Jason.encode!([%{name: "Setup", description: "x"}]))
      assert Readiness.step_complete?(:categories, game, [])

      # First-time auto-save deletes the draft and writes the table; still done.
      Settings.delete("categories_#{game.id}")
      Games.replace_game_categories(game, [%{name: "Setup", description: "How to set up"}])
      assert Readiness.step_complete?(:categories, game, [])
    end
  end

  describe "state/1" do
    test "enrichment steps are blocked until embed is done" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}], embed: :pending)

      states = Map.new(Readiness.state(game), &{&1.id, &1.state})

      for step <- Readiness.enrichment_steps() do
        assert states[step] == :blocked, "expected #{step} blocked before embed"
      end
    end

    test "enrichment steps unblock once embed is done" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}], embed: :done)

      states = Map.new(Readiness.state(game), &{&1.id, &1.state})

      for step <- Readiness.enrichment_steps() do
        assert states[step] == :pending, "expected #{step} pending after embed"
      end
    end
  end

  describe "recompute/1" do
    test "stays unplayable until required steps are done" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}], status: "cleaned", embed: :pending)

      refute Readiness.recompute(game)
      assert Repo.reload(game).playable == false
    end

    test "required-complete is not enough without publish approval (manual gate)" do
      game = game_fixture(name: "ready", bgg_id: 102, bgg_data: "<items/>")
      doc_fixture(game, pages: [{0.9, true}], status: "cleaned", embed: :done)

      assert Readiness.required_complete?(game)
      # The gate holds playable false even though every required step is done.
      refute Readiness.recompute(game)
      assert Repo.reload(game).playable == false

      # Approving publishes it.
      assert Readiness.approve_publish(game)
      reloaded = Repo.reload(game)
      assert reloaded.playable == true
      assert reloaded.playable_at != nil

      # Revoking pulls it back out of playable immediately.
      refute Readiness.revoke_publish(reloaded)
      assert Repo.reload(game).playable == false
    end

    test "approved playable game appears in list_playable_games/0" do
      game = game_fixture(name: "ready2", bgg_data: "<items/>")
      doc_fixture(game, pages: [{0.9, true}], status: "cleaned", embed: :done)
      Readiness.approve_publish(game)

      ids = Enum.map(Games.list_playable_games(), & &1.id)
      assert game.id in ids
    end
  end

  describe "drive/1 auto-pilot decisions" do
    # BGG is the first required step. Games past it in these tests carry
    # bgg_data so drive advances to the stage under test.
    test "pauses for BGG when there is no bgg_id to pull" do
      game = game_fixture(bgg_id: nil)
      assert {:paused, "needs_bgg"} = Readiness.drive(game)
      assert Readiness.pause_reason(game.id) == "needs_bgg"
    end

    test "runs the BGG pull first when a bgg_id is set but not yet pulled" do
      game = game_fixture(bgg_id: 42)
      assert {:running, :bgg} = Readiness.drive(game)
    end

    test "pauses needing a source on a bgg-pulled empty game" do
      game = game_fixture(bgg_data: "<items/>")
      assert {:paused, "needs_source"} = Readiness.drive(game)
      assert Readiness.pause_reason(game.id) == "needs_source"
    end

    test "runs extraction (not a pause) when a source is saved but unextracted" do
      game = game_fixture(bgg_data: "<items/>")

      {:ok, _doc} =
        %Document{}
        |> Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          pdf_path: "uploads/rulebooks/x.pdf",
          pages: []
        })
        |> Repo.insert()

      assert {:running, :extract} = Readiness.drive(game)
    end

    test "pauses for human review when pages are flagged" do
      game = game_fixture(bgg_data: "<items/>")
      doc_fixture(game, pages: [{0.9, true}, {0.2, true}])
      assert {:paused, "needs_review"} = Readiness.drive(game)
    end

    test "reaches done and disarms once required steps complete" do
      game = game_fixture(bgg_data: "<items/>")
      doc_fixture(game, pages: [{0.9, true}], status: "cleaned", embed: :done)
      Settings.put("readiness_auto_#{game.id}", "on")

      assert :done = Readiness.drive(game)
      assert Readiness.auto?(game.id) == false
    end
  end

  describe "Estimator" do
    test "remaining cost is positive for a fresh extracted game" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, false}, {0.9, false}])
      assert Estimator.remaining_cost(game) > 0.0
    end

    test "a completed or non-LLM step estimates zero" do
      game = game_fixture()
      doc_fixture(game, pages: [{0.9, true}])
      # :review is non-LLM → always 0.0
      assert Estimator.step_cost(:review, game) == 0.0
      # :cleanup already done (page cleaned) → 0.0
      assert Estimator.step_cost(:cleanup, game) == 0.0
    end
  end
end
