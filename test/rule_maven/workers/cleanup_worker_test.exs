defmodule RuleMaven.Workers.CleanupWorkerTest do
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.Games
  alias RuleMaven.Jobs
  alias RuleMaven.Workers.CleanupWorker

  # Stub the LLM at do_request: uppercase the page text so the cleaned layer is
  # distinguishable and long enough to clear cleanup_page's "kept >= half" guard.
  setup do
    Application.put_env(:rule_maven, :llm_mock, fn body ->
      content = body.messages |> List.last() |> Map.fetch!(:content)
      {:ok, %{answer: String.upcase(content)}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    :ok
  end

  defp doc_with_pages(full_text) do
    {:ok, game} = Games.create_game(%{name: "Cleanup #{System.unique_integer([:positive])}"})
    {:ok, doc} = Games.create_document(%{game_id: game.id, label: "Rules", full_text: full_text})
    doc
  end

  defp run(doc, extra_args \\ %{}) do
    args = Map.merge(%{"document_id" => doc.id, "game_id" => doc.game_id}, extra_args)
    assert :ok = CleanupWorker.perform(%Oban.Job{args: args})
    Games.get_document!(doc.id)
  end

  test "cleans every page into the cleaned layer" do
    doc = doc_with_pages("alpha rules here\fbeta rules here\fgamma rules here")

    cleaned = run(doc) |> Map.fetch!(:pages) |> Enum.map(& &1.cleaned)

    assert cleaned == ["ALPHA RULES HERE", "BETA RULES HERE", "GAMMA RULES HERE"]
  end

  test "durable progress counter advances then clears when done" do
    doc = doc_with_pages("alpha rules here\fbeta rules here\fgamma rules here")
    Games.set_cleaning_done(doc.id, 0)

    refreshed = run(doc)

    # All three pages persisted, and the counter is cleared (idle) on completion.
    assert Enum.count(refreshed.pages, &is_binary(&1.cleaned)) == 3
    assert Games.cleaning_done(doc.id) == nil
  end

  test "resumes the counter from its durable value instead of restarting it" do
    doc = doc_with_pages("alpha rules here\fbeta rules here\fgamma rules here")
    # Simulate a restart: page 0 already done and the counter persisted at 1.
    Games.set_page_cleaned(doc.id, 0, "ALPHA RULES HERE")
    Games.set_cleaning_done(doc.id, 1)

    # Re-fetch so perform sees the persisted counter, then run to completion.
    run(Games.get_document!(doc.id))

    # 1 (resumed) + 2 newly cleaned pages = 3 total, not 2.
    refute Games.cleanup_running?(doc.id)
    assert Games.cleaning_done(doc.id) == nil
  end

  test "resumes — pages already cleaned are left untouched" do
    doc = doc_with_pages("alpha rules here\fbeta rules here\fgamma rules here")

    # Simulate a prior run that finished page 1 before a restart.
    Games.set_page_cleaned(doc.id, 1, "PRESERVED")

    pages = run(doc) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [
             "ALPHA RULES HERE",
             "PRESERVED",
             "GAMMA RULES HERE"
           ]
  end

  test "strips the printed page number from the body during cleanup" do
    # Marker blob gives each page a detected printed number; the footer digit
    # should be removed from the body (it's stored separately as `printed`).
    blob = Games.number_pages(["body text here\n1", "more rules text\n2"])
    {:ok, game} = Games.create_game(%{name: "Strip #{System.unique_integer([:positive])}"})
    {:ok, doc} = Games.create_document(%{game_id: game.id, label: "Rules", full_text: blob})

    pages = run(doc) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.printed) == [1, 2]
    assert Enum.map(pages, & &1.cleaned) == ["BODY TEXT HERE", "MORE RULES TEXT"]
  end

  test "mode 'again' re-cleans the existing cleaned layer, not the raw text" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")
    # A prior clean (+ hand-edit) left a distinct cleaned copy on page 0.
    Games.set_page_cleaned(doc.id, 0, "manually fixed alpha")

    pages = run(doc, %{"mode" => "again"}) |> Map.fetch!(:pages)

    # Page 0 was re-cleaned from its cleaned text (would be "ALPHA RULES HERE"
    # if it had used the raw text instead); page 1 had none, so it used raw.
    assert Enum.map(pages, & &1.cleaned) == ["MANUALLY FIXED ALPHA", "BETA RULES HERE"]
  end

  test "an unknown level falls back to auto instead of crashing" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")

    cleaned = run(doc, %{"level" => "bogus"}) |> Map.fetch!(:pages) |> Enum.map(& &1.cleaned)

    assert cleaned == ["ALPHA RULES HERE", "BETA RULES HERE"]
  end

  test "cleanup_running? reflects an active Oban job for the document" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")
    refute Games.cleanup_running?(doc.id)

    # Insert the job row directly (Oban isn't supervised in test).
    %{document_id: doc.id, game_id: doc.game_id}
    |> CleanupWorker.new()
    |> Repo.insert!()

    assert Games.cleanup_running?(doc.id)
  end

  test "cleanup_running? ignores finished jobs" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")

    %{document_id: doc.id, game_id: doc.game_id}
    |> CleanupWorker.new()
    |> Ecto.Changeset.put_change(:state, "completed")
    |> Repo.insert!()

    refute Games.cleanup_running?(doc.id)
  end

  test "clear_all_cleaned nulls every page's cleaned layer" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")
    Games.set_page_cleaned(doc.id, 0, "STALE")

    cleared = Games.get_document!(doc.id) |> Games.clear_all_cleaned()

    assert Enum.map(cleared.pages, & &1.cleaned) == [nil, nil]
  end

  defp run_summary(doc) do
    [run_row] = Jobs.list_runs(scope_type: "document", scope_id: doc.id, kind: "cleanup", limit: 1)
    run_row.summary
  end

  test "first-run summary does not claim re-chunked when the doc had no chunks" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")
    # Mimic the upload→extract path, where chunking is a later explicit step
    # (create_document auto-chunks only pasted/full_text sources).
    Repo.delete_all(from(c in RuleMaven.Games.Chunk, where: c.document_id == ^doc.id))
    refute Games.document_chunked?(doc.id)

    run(doc)

    refute Games.document_chunked?(doc.id)

    summary = run_summary(doc)
    assert summary =~ "Cleaned 2/2 pages"
    refute summary =~ "re-chunked"
  end

  test "re-clean of an already-chunked doc reports re-chunked" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")
    Games.chunk_document(doc)
    assert Games.document_chunked?(doc.id)

    run(doc, %{"mode" => "again"})

    assert run_summary(doc) =~ "re-chunked"
  end

  # ── Auto-escalation loop ──

  # Distinct system prompts per level so the mock can tell attempts apart, and
  # a scripted responder: cleans answer from `script` keyed by level marker,
  # critic answers popped from the `critic` list (in call order).
  defp install_auto_mock(script, critic_replies) do
    RuleMaven.Settings.put("prompt_cleanup_light", "MARK_LIGHT clean the page")
    RuleMaven.Settings.put("prompt_cleanup_standard", "MARK_STANDARD clean the page")
    RuleMaven.Settings.put("prompt_cleanup_aggressive", "MARK_AGGRESSIVE clean the page")

    {:ok, agent} = Agent.start_link(fn -> %{critic: critic_replies, calls: []} end)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      system =
        body.messages
        |> Enum.find(&(&1.role == "system" or &1[:role] == "system"))
        |> then(&(&1 && (&1[:content] || &1.content))) || ""

      cond do
        system =~ "adversarial reviewer" ->
          Agent.get_and_update(agent, fn %{critic: [h | t]} = s ->
            reply = if match?({:error, _}, h), do: h, else: {:ok, %{answer: h}}
            {reply, %{s | critic: t, calls: s.calls ++ [:critic]}}
          end)

        system =~ "MARK_LIGHT" ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:light]})
          {:ok, %{answer: script.light}}

        system =~ "MARK_AGGRESSIVE" ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:aggressive]})
          {:ok, %{answer: script.aggressive}}

        true ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:standard]})
          {:ok, %{answer: script.standard}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    agent
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  @good_page "Each player draws five cards at the start of the game and keeps them hidden. On your turn you may play one card and then move your pawn up to three spaces."
  @garbled_page @good_page <> "\n~~ %% §§ x7 qq zz ##"
  @good_clean String.upcase(@good_page)

  test "auto: clean page accepts at standard with no critic call" do
    agent = install_auto_mock(%{standard: @good_clean, light: "L", aggressive: "A"}, [])
    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard]
  end

  test "auto: junk_remains escalates to aggressive and keeps the faithful retry" do
    # Standard "clean" leaves the garble in → heuristic suspect → critic says
    # junk_remains → retry aggressive → clean output → critic faithful.
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " tidied", light: "L", aggressive: @good_clean},
        ["VERDICT: junk_remains\n- GARBLE: \"~~ %%\" survived", "VERDICT: faithful\nNONE"]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard, :critic, :aggressive, :critic]
  end

  test "auto: content_lost de-escalates to light" do
    # Standard cut too hard (beyond envelope) → critic content_lost → retry
    # light → faithful.
    short = String.slice(@good_clean, 0, div(String.length(@good_clean), 2))

    agent =
      install_auto_mock(
        %{standard: short, light: @good_clean, aggressive: "A"},
        ["VERDICT: content_lost\n- DROPPED: pawn movement", "VERDICT: faithful\nNONE"]
      )

    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard, :critic, :light, :critic]
  end

  test "auto: guard-fired but faithful short output is accepted, not reverted" do
    # Aggressive-style legit big cut at standard: below the 0.5 floor, soft
    # guard keeps it, critic adjudicates faithful → accepted as-is.
    tiny = "Draw five cards. Play one card. Move three."

    agent =
      install_auto_mock(%{standard: tiny, light: "L", aggressive: "A"}, [
        "VERDICT: faithful\nNONE"
      ])

    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [tiny]
    assert calls(agent) == [:standard, :critic]
  end

  test "auto: still bad after retry keeps best attempt and flags the page" do
    # Both attempts junky; retry's verdict is also junk_remains → flag, keep
    # the attempt ranked best (equal verdicts → fewer defects wins: attempt 2).
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " a", light: "L", aggressive: @garbled_page <> " b"},
        [
          "VERDICT: junk_remains\n- GARBLE: soup\n- JUNK: header",
          "VERDICT: junk_remains\n- GARBLE: soup"
        ]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@garbled_page <> " b"]
    assert calls(agent) == [:standard, :critic, :aggressive, :critic]

    # The winning attempt still carried defects (junk_remains) → the page must
    # be flagged in the job log, not silently accepted.
    run_row = Jobs.list_runs(scope_type: "document", scope_id: doc.id, kind: "cleanup", limit: 1) |> hd()
    messages = Jobs.events(run_row.id) |> Enum.map(& &1.message)
    assert Enum.any?(messages, &(&1 =~ "cleanup review flagged"))

    # …and persisted on the page itself so the Prepare page's ⚠ review UI
    # (page_needs_review?) can surface it, not just the job log.
    page = hd(pages)
    assert page.cleanup_defects == ["GARBLE: soup"]
    assert Games.page_needs_review?(page)
  end

  test "auto: a faithful re-clean clears defects a prior run recorded" do
    agent = install_auto_mock(%{standard: @good_clean, light: "L", aggressive: "A"}, [])
    doc = doc_with_pages(@good_page)
    # Prior run left the page flagged (defects on record, junky cleaned copy).
    Games.set_page_cleaned(doc.id, 0, @good_page, ["GARBLE: soup"])
    assert Games.page_needs_review?(hd(Games.get_document!(doc.id).pages))

    pages = run(doc, %{"level" => "auto", "mode" => "again"}) |> Map.fetch!(:pages)

    page = hd(pages)
    assert page.cleaned == @good_clean
    assert page.cleanup_defects == []
    refute Games.page_needs_review?(page)
    assert calls(agent) == [:standard]
  end

  test "auto: guard-fired attempt whose critic call errors reverts to raw (legacy hard-guard)" do
    # Below-floor output at standard with soft guard kept → :guard_fired. If the
    # critic call itself fails (not a bad verdict — a network/parse error),
    # there's nothing vouching for a likely-truncated output, so it reverts to
    # the raw page rather than silently persisting it.
    tiny = "Draw five cards. Play one card. Move three."

    agent =
      install_auto_mock(%{standard: tiny, light: "L", aggressive: "A"}, [{:error, :boom}])

    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_page]
    assert calls(agent) == [:standard, :critic]
  end

  test "auto: suspect (non-guard) attempt whose critic call errors persists the attempt as-is" do
    # Standard leaves garble in → heuristic suspect :under (not guard_fired).
    # The critic call errors — critic failure never blocks, so the attempt's
    # own (unverified) text is persisted rather than reverted, and there's no
    # retry (no verdict to pick a direction from).
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " tidied", light: "L", aggressive: @good_clean},
        [{:error, :boom}]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@garbled_page <> " tidied"]
    assert calls(agent) == [:standard, :critic]
  end

  test "auto: second attempt's critic call errors → persists the already-judged first attempt" do
    # First attempt is judged (junk_remains), retry runs, but the retry's
    # critic call errors — the unranked/unverified second attempt must not be
    # allowed to win over the already-judged first.
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " a", light: "L", aggressive: @garbled_page <> " b"},
        ["VERDICT: junk_remains\n- GARBLE: soup", {:error, :boom}]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@garbled_page <> " a"]
    assert calls(agent) == [:standard, :critic, :aggressive, :critic]
  end

  test "auto: junky input returned verbatim at standard is suspect and gets a critic call" do
    # No single line has a garble-line's ≥3-token minimum (each line pairs one
    # wordish word with a 2-char code), yet the overall wordish ratio is well
    # under 0.6 — junky by the low-wordishness signal alone. `cleanup_page`
    # returns this verbatim (`:cleaned` by its own logic since nothing shrank),
    # so `attempt/4` must reclassify it to `:unchanged` before CleanCheck sees
    # it, or the junky-verbatim suspect branch never fires.
    fixture =
      Enum.join(
        [
          "sword x7",
          "shield q2",
          "armor b3",
          "potion c4",
          "dragon d5",
          "wizard e6",
          "castle f7",
          "forest g8",
          "river h9",
          "mountain j0"
        ],
        "\n"
      )

    assert RuleMaven.Extract.Gate.wordish_ratio(fixture) < 0.6
    assert RuleMaven.Extract.CleanCheck.garble_lines(fixture) == 0

    agent =
      install_auto_mock(%{standard: fixture, light: "L", aggressive: "A"}, [
        "VERDICT: faithful\nNONE"
      ])

    doc = doc_with_pages(fixture)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [fixture]
    assert calls(agent) == [:standard, :critic]
  end

  test "explicit level still runs the single-shot legacy path (no critic)" do
    agent = install_auto_mock(%{standard: "S", light: @good_clean, aggressive: "A"}, [])
    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "light"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:light]
  end

  describe "skippable_page?/3" do
    defp skip_page(attrs), do: Map.merge(%{lane: "ensemble", confidence: 0.8}, attrs)

    test "vision-lane, confident page is skippable at auto level" do
      assert CleanupWorker.skippable_page?(skip_page(%{lane: "ensemble"}), :auto, false)
      assert CleanupWorker.skippable_page?(skip_page(%{lane: "vision"}), :auto, false)
    end

    test "text_layer and ocr lanes are never skipped" do
      refute CleanupWorker.skippable_page?(skip_page(%{lane: "text_layer"}), :auto, false)
      refute CleanupWorker.skippable_page?(skip_page(%{lane: "ocr"}), :auto, false)
      refute CleanupWorker.skippable_page?(skip_page(%{lane: nil}), :auto, false)
    end

    test "low or missing confidence disqualifies the skip" do
      refute CleanupWorker.skippable_page?(skip_page(%{confidence: 0.5}), :auto, false)
      refute CleanupWorker.skippable_page?(skip_page(%{confidence: nil}), :auto, false)
    end

    test "explicit levels and forced single-page runs always clean" do
      refute CleanupWorker.skippable_page?(skip_page(%{}), :standard, false)
      refute CleanupWorker.skippable_page?(skip_page(%{}), :aggressive, false)
      refute CleanupWorker.skippable_page?(skip_page(%{}), :light, false)
      refute CleanupWorker.skippable_page?(skip_page(%{}), :auto, true)
    end
  end

  test "auto run skips confident vision-lane pages without calling the LLM" do
    Application.put_env(:rule_maven, :llm_mock, fn _ -> raise "LLM must not be called" end)
    # Deterministic: sampling off.
    RuleMaven.Settings.put("cleanup_skip_sample_rate", "0.0")

    doc = doc_with_pages("alpha rules here\fbeta rules here")

    vision_pages =
      Enum.map(doc.pages, fn p ->
        %{index: p.index, sheet: p.sheet, printed: p.printed, text: p.text, lane: "ensemble", confidence: 0.9}
      end)

    {:ok, doc} = Games.update_document(doc, %{pages: vision_pages}, chunk: false)

    refreshed = run(doc, %{"level" => "auto"})

    assert Enum.all?(refreshed.pages, &is_nil(&1.cleaned))
    assert Games.cleaning_done(doc.id) == nil
  end

  test "forced single-page run cleans a vision-lane page anyway" do
    RuleMaven.Settings.put("cleanup_skip_sample_rate", "0.0")
    doc = doc_with_pages("alpha rules here\fbeta rules here")

    vision_pages =
      Enum.map(doc.pages, fn p ->
        %{index: p.index, sheet: p.sheet, printed: p.printed, text: p.text, lane: "ensemble", confidence: 0.9}
      end)

    {:ok, doc} = Games.update_document(doc, %{pages: vision_pages}, chunk: false)

    refreshed = run(doc, %{"page_index" => 0})

    assert Enum.at(refreshed.pages, 0).cleaned == "ALPHA RULES HERE"
  end
end
