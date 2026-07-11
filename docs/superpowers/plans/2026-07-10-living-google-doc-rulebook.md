# Living Google Doc Rulebook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a game's core rulebook in sync with a continually-edited public Google Doc, re-embedding and invalidating only the answers affected by each edit instead of the whole pool.

**Architecture:** Add a content-hash identity to chunks so re-chunking becomes an upsert (unchanged chunks keep their row ID + embedding) that returns a `dirty_chunk_ids` set. A daily Oban worker fetches the doc's HTML export, hash-gates for changes, re-chunks with heading-anchored sections, and stales only pooled answers whose `source_chunk_ids` overlap the dirty set (Postgres array overlap). Live-source metadata lives on the existing `documents` row.

**Tech Stack:** Elixir/Phoenix, Ecto/Postgres (pgvector), Oban (cron + workers), Req (HTTP), Floki (HTML parsing — new dep).

## Global Constraints

- Elixir/Phoenix LiveView app; Ecto + Postgres with pgvector.
- Every new worker reports to the unified Jobs log via `Jobs.start_run/4` + `Jobs.finish_run/3` (job-log convention).
- Background work is durable Oban, never blocks a LiveView (background-work-durable rule).
- Do NOT break the existing non-live chunking path: `chunk_document/1` has 7 callers (uploads, cleanup, readiness, scrub). Its observable output (the resulting chunk set for a document) must stay identical; only chunk *identity stability* and the *return value* change.
- Never let an empty/failed fetch wipe a document's chunks (mirror existing `blank_page_text?` guard).
- Migrations are additive; existing uploaded rulebooks keep working with `live_source = false`.
- Testing lesson (from prior rounds): for any staleness/invalidation change, confirm the new test FAILS against current behavior before wiring the fix. Run only the test files relevant to the change.

---

### Task 1: Add `content_hash` to chunks

**Files:**
- Create: `priv/repo/migrations/20260710120000_add_content_hash_to_chunks.exs`
- Modify: `lib/rule_maven/games/chunk.ex`
- Test: `test/rule_maven/games/chunk_test.exs`

**Interfaces:**
- Produces: `chunks.content_hash :string` column; `Chunk.changeset/2` casts `:content_hash`; index `(document_id, content_hash)`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddContentHashToChunks do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      add :content_hash, :string
    end

    create index(:chunks, [:document_id, :content_hash])
  end
end
```

- [ ] **Step 2: Add the field + cast**

In `lib/rule_maven/games/chunk.ex`, add to the schema (after `:page_number`):

```elixir
    field :content_hash, :string
```

And add `:content_hash` to the `cast/3` list in `changeset/2`.

- [ ] **Step 3: Write a failing test for the changeset cast**

```elixir
defmodule RuleMaven.Games.ChunkTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games.Chunk

  test "changeset casts content_hash" do
    cs = Chunk.changeset(%Chunk{}, %{document_id: 1, chunk_index: 0, content: "x", content_hash: "abc"})
    assert Ecto.Changeset.get_change(cs, :content_hash) == "abc"
  end
end
```

- [ ] **Step 4: Run migration + test**

Run: `mix ecto.migrate && mix test test/rule_maven/games/chunk_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260710120000_add_content_hash_to_chunks.exs lib/rule_maven/games/chunk.ex test/rule_maven/games/chunk_test.exs
git commit -m "feat(chunks): add content_hash column for stable identity"
```

---

### Task 2: Reconcile re-chunk (upsert by content_hash, return dirty ids)

**Files:**
- Modify: `lib/rule_maven/games.ex` (the `chunk_document/1` insert block, ~line 3705, and add `reconcile_chunks/2` + `chunk_content_hash/1` helpers)
- Test: `test/rule_maven/games/reconcile_chunks_test.exs`

**Interfaces:**
- Consumes: `chunks.content_hash` (Task 1).
- Produces:
  - `Games.chunk_document/1` now returns `{:ok, dirty_chunk_ids :: [integer]}` (was the `Repo.transaction` result). All 7 existing callers ignore the return value, so this is safe.
  - `Games.chunk_content_hash(content :: String.t()) :: String.t()` — SHA-256 hex of whitespace-normalized content.
  - Private `reconcile_chunks(doc_id, desired_rows) :: [integer]` where `desired_rows` are the chunk attr maps (with `:content_hash`), returning `dirty_chunk_ids`.

**Design:** Identity is `(document_id, content_hash)`. Match each desired chunk to an unused existing row with the same hash. Matched rows are **kept** (ID + embedding untouched; `chunk_index`/`section_label`/`references_section`/`page_number` updated in place if they differ — a reorder is not "dirty"). Unmatched desired rows are inserted (embedding nil). Unmatched existing rows are deleted. `dirty_chunk_ids = inserted_ids ++ deleted_ids`. On first run, existing rows have `content_hash = nil` → no matches → one-time full re-insert (all dirty), which is acceptable.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule RuleMaven.Games.ReconcileChunksTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.Chunk
  import Ecto.Query

  # Build a document with a known full_text and chunk it once.
  setup do
    {:ok, game} = Games.create_game(%{name: "Recon", bgg_id: nil})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        kind: "rulebook",
        full_text: "Section one text about setup.\fSection two text about combat.",
        status: "published"
      })

    %{doc: doc}
  end

  defp chunks(doc_id) do
    Repo.all(from c in Chunk, where: c.document_id == ^doc_id, order_by: c.chunk_index)
  end

  test "unchanged re-chunk keeps chunk IDs and reports no dirty", %{doc: doc} do
    {:ok, _} = Games.chunk_document(doc)
    before = chunks(doc.id)
    before_ids = Enum.map(before, & &1.id)

    # Simulate embeddings already present so we can assert they survive.
    Enum.each(before, fn c ->
      Repo.update_all(from(x in Chunk, where: x.id == ^c.id), set: [content: c.content])
    end)

    {:ok, dirty} = Games.chunk_document(Games.get_document!(doc.id))
    after_ids = chunks(doc.id) |> Enum.map(& &1.id)

    assert dirty == []
    assert Enum.sort(after_ids) == Enum.sort(before_ids)
  end

  test "editing one page marks only that page's chunks dirty", %{doc: doc} do
    {:ok, _} = Games.chunk_document(doc)
    before = chunks(doc.id)
    unchanged_chunk = Enum.find(before, &String.contains?(&1.content, "setup"))

    # Edit only the second page's text.
    {:ok, doc2} =
      Games.update_document(doc, %{
        full_text: "Section one text about setup.\fSection two text about combat and MOVEMENT."
      })

    {:ok, dirty} = Games.chunk_document(Games.get_document!(doc2.id))

    # The unchanged chunk kept its ID and is not dirty.
    assert unchanged_chunk.id in (chunks(doc.id) |> Enum.map(& &1.id))
    refute unchanged_chunk.id in dirty
    assert dirty != []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/rule_maven/games/reconcile_chunks_test.exs`
Expected: FAIL — `chunk_document/1` returns the old `Repo.transaction` tuple (not `{:ok, dirty}`) and delete-all/insert-all gives every chunk a new ID.

- [ ] **Step 3: Add the hash helper**

In `lib/rule_maven/games.ex`, add (near the other chunk helpers):

```elixir
  @doc """
  Stable content hash for a chunk: SHA-256 hex of the content with runs of
  whitespace collapsed and ends trimmed. Chunk identity within a document is
  `(document_id, content_hash)`, so cosmetic whitespace churn does not create a
  "changed" chunk.
  """
  def chunk_content_hash(content) when is_binary(content) do
    normalized = content |> String.replace(~r/\s+/u, " ") |> String.trim()
    :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
  end
```

- [ ] **Step 4: Replace the insert block with reconcile**

In `chunk_document/1`, the `rows = Enum.map(...)` builder must add `content_hash`. Change the row map to include:

```elixir
        %{
          document_id: doc.id,
          chunk_index: idx,
          content: text,
          section_label: section,
          references_section: refs,
          page_number: pn,
          content_hash: chunk_content_hash(text),
          inserted_at: now,
          updated_at: now
        }
```

Then replace the closing `Repo.transaction(fn -> Repo.delete_all(...) ; Repo.insert_all(...) end)` block **and** the trailing embed-enqueue with:

```elixir
    dirty_ids =
      Repo.transaction(fn -> reconcile_chunks(doc.id, rows, now) end)
      |> case do
        {:ok, ids} -> ids
        {:error, reason} -> raise "reconcile_chunks failed: #{inspect(reason)}"
      end

    # Enqueue embedding only when there are un-embedded chunks (new rows have a
    # nil embedding; kept rows retain theirs). EmbedChunksWorker already filters
    # `where is_nil(embedding)`, so this is a no-op when nothing changed.
    if dirty_ids != [] and not testing?() do
      %{document_id: doc.id}
      |> RuleMaven.Workers.EmbedChunksWorker.new()
      |> Oban.insert()
    end

    {:ok, dirty_ids}
  end

  # Upsert chunk rows by (document_id, content_hash). Kept rows retain their id
  # and embedding; only chunk_index/section/refs/page are updated in place.
  # Returns dirty ids = inserted ++ deleted (a content change is a delete+insert).
  defp reconcile_chunks(doc_id, desired_rows, now) do
    existing = Repo.all(from c in Chunk, where: c.document_id == ^doc_id)

    existing_by_hash =
      Enum.group_by(existing, & &1.content_hash)

    {kept_updates, to_insert, leftover} =
      Enum.reduce(desired_rows, {[], [], existing_by_hash}, fn row, {keep, ins, pool} ->
        case Map.get(pool, row.content_hash) do
          [match | rest] ->
            pool = Map.put(pool, row.content_hash, rest)
            keep = [{match, row} | keep]
            {keep, ins, pool}

          _ ->
            {keep, [row | ins], pool}
        end
      end)

    delete_ids =
      leftover |> Map.values() |> List.flatten() |> Enum.map(& &1.id)

    if delete_ids != [] do
      Repo.delete_all(from c in Chunk, where: c.id in ^delete_ids)
    end

    inserted_ids =
      if to_insert == [] do
        []
      else
        {_, returned} = Repo.insert_all(Chunk, Enum.reverse(to_insert), returning: [:id])
        Enum.map(returned, & &1.id)
      end

    # Update kept rows' position/metadata in place (never their embedding).
    Enum.each(kept_updates, fn {match, row} ->
      if match.chunk_index != row.chunk_index or match.section_label != row.section_label or
           match.references_section != row.references_section or match.page_number != row.page_number do
        Repo.update_all(
          from(c in Chunk, where: c.id == ^match.id),
          set: [
            chunk_index: row.chunk_index,
            section_label: row.section_label,
            references_section: row.references_section,
            page_number: row.page_number,
            updated_at: now
          ]
        )
      end
    end)

    inserted_ids ++ delete_ids
  end
```

- [ ] **Step 5: Run the test**

Run: `mix test test/rule_maven/games/reconcile_chunks_test.exs`
Expected: PASS.

- [ ] **Step 6: Regression — run existing chunk/upload tests**

Run: `mix test test/rule_maven/games_test.exs`
Expected: PASS (callers ignore the new return value).

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games/reconcile_chunks_test.exs
git commit -m "feat(chunks): reconcile re-chunk by content_hash, return dirty ids"
```

---

### Task 3: Live-source metadata on documents

**Files:**
- Create: `priv/repo/migrations/20260710121000_add_live_source_to_documents.exs`
- Modify: `lib/rule_maven/games/document.ex`
- Test: `test/rule_maven/games/document_test.exs`

**Interfaces:**
- Produces: `documents.live_source :boolean (default false)`, `documents.doc_content_hash :string`, `documents.synced_at :utc_datetime`; all three cast in `Document.changeset/2`. (Named `doc_content_hash` to avoid confusion with the existing `file_hash` and the new chunk `content_hash`.)

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddLiveSourceToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :live_source, :boolean, default: false, null: false
      add :doc_content_hash, :string
      add :synced_at, :utc_datetime
    end
  end
end
```

- [ ] **Step 2: Add fields + cast**

In `lib/rule_maven/games/document.ex` schema:

```elixir
    field :live_source, :boolean, default: false
    field :doc_content_hash, :string
    field :synced_at, :utc_datetime
```

Add `:live_source, :doc_content_hash, :synced_at` to the `cast/3` list in `changeset/2`.

- [ ] **Step 3: Write a failing test**

```elixir
defmodule RuleMaven.Games.DocumentTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games.Document

  test "changeset casts live-source fields" do
    cs =
      Document.changeset(%Document{}, %{
        game_id: 1,
        label: "L",
        live_source: true,
        source_url: "https://docs.google.com/document/d/ABC/edit",
        doc_content_hash: "h"
      })

    assert Ecto.Changeset.get_change(cs, :live_source) == true
    assert Ecto.Changeset.get_change(cs, :doc_content_hash) == "h"
  end
end
```

- [ ] **Step 4: Run migration + test**

Run: `mix ecto.migrate && mix test test/rule_maven/games/document_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260710121000_add_live_source_to_documents.exs lib/rule_maven/games/document.ex test/rule_maven/games/document_test.exs
git commit -m "feat(documents): live_source + sync metadata columns"
```

---

### Task 4: Chunk-scoped staleness (`mark_stale_for_chunks/2`)

**Files:**
- Modify: `lib/rule_maven/games.ex` (add `mark_stale_for_chunks/2` near `mark_stale_for_game`, ~line 1195)
- Test: `test/rule_maven/games/mark_stale_for_chunks_test.exs`

**Interfaces:**
- Consumes: `questions_log.source_chunk_ids {:array, :integer}`, `stale`, `pooled`, `needs_review`.
- Produces: `Games.mark_stale_for_chunks(game_id, dirty_chunk_ids :: [integer]) :: non_neg_integer` — stales/demotes only rows whose `source_chunk_ids` overlaps `dirty_chunk_ids`; returns affected count. No-op returning 0 when `dirty_chunk_ids == []`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule RuleMaven.Games.MarkStaleForChunksTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  setup do
    {:ok, game} = Games.create_game(%{name: "Stale", bgg_id: nil})
    %{game: game}
  end

  defp q(game_id, chunk_ids) do
    %QuestionLog{}
    |> QuestionLog.changeset(%{
      game_id: game_id,
      question: "q",
      answer: "a",
      pooled: true,
      stale: false,
      visibility: "community",
      source_chunk_ids: chunk_ids
    })
    |> Repo.insert!()
  end

  test "only answers citing a dirty chunk go stale", %{game: game} do
    hit = q(game.id, [10, 11])
    miss = q(game.id, [20, 21])

    affected = Games.mark_stale_for_chunks(game.id, [11, 99])

    assert affected == 1
    assert Repo.reload(hit).stale == true
    assert Repo.reload(hit).pooled == false
    assert Repo.reload(miss).stale == false
    assert Repo.reload(miss).pooled == true
  end

  test "empty dirty set is a no-op", %{game: game} do
    hit = q(game.id, [10])
    assert Games.mark_stale_for_chunks(game.id, []) == 0
    assert Repo.reload(hit).stale == false
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/rule_maven/games/mark_stale_for_chunks_test.exs`
Expected: FAIL with "function mark_stale_for_chunks/2 is undefined".

- [ ] **Step 3: Implement**

In `lib/rule_maven/games.ex`, add:

```elixir
  @doc """
  Content-staleness scoped to a set of changed chunk ids (the byproduct of a
  reconcile re-chunk). Only pooled/served answers whose `source_chunk_ids`
  overlap `dirty_chunk_ids` are demoted + staled; community rows also get
  `needs_review` so they leave the shared pool until re-approved. Answers citing
  only untouched chunks stay warm.

  This is the surgical counterpart to `mark_stale_for_game/1` — used by the live
  Google Doc sync so a minor edit does not nuke the whole answer pool. Returns
  the number of affected rows.
  """
  def mark_stale_for_chunks(_game_id, []), do: 0

  def mark_stale_for_chunks(game_id, dirty_chunk_ids) when is_list(dirty_chunk_ids) do
    base =
      from(q in QuestionLog,
        where:
          (q.game_id == ^game_id or fragment("? = ANY(?)", ^game_id, q.expansion_ids)) and
            fragment("? && ?", q.source_chunk_ids, ^dirty_chunk_ids)
      )

    {affected, _} =
      Repo.update_all(
        from(q in base, where: q.stale == false or q.pooled == true),
        set: [stale: true, pooled: false]
      )

    Repo.update_all(
      from(q in base, where: q.visibility == "community" and q.needs_review == false),
      set: [needs_review: true]
    )

    affected
  end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/rule_maven/games/mark_stale_for_chunks_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games/mark_stale_for_chunks_test.exs
git commit -m "feat(games): mark_stale_for_chunks — chunk-scoped pool invalidation"
```

---

### Task 5: Heading-anchored chunking for live docs

**Files:**
- Modify: `mix.exs` (add Floki dep)
- Create: `lib/rule_maven/games/google_doc.ex`
- Modify: `lib/rule_maven/games.ex` (`chunk_document/1` branches on `doc.live_source`)
- Test: `test/rule_maven/games/google_doc_test.exs`

**Interfaces:**
- Produces:
  - `RuleMaven.Games.GoogleDoc.export_url(source_url, format) :: {:ok, String.t()} | :error` — derives `https://docs.google.com/document/d/<ID>/export?format=<fmt>` from any doc URL.
  - `RuleMaven.Games.GoogleDoc.fetch_html(source_url) :: {:ok, String.t()} | {:error, term}` — fetches the HTML export via Req.
  - `RuleMaven.Games.GoogleDoc.sections_from_html(html) :: [%{label: String.t() | nil, text: String.t()}]` — splits on `<h1>`–`<h3>` into heading-anchored blocks.
- Consumes (in `chunk_document`): `GoogleDoc.sections_from_html/1` when `doc.live_source`.

- [ ] **Step 1: Add Floki**

In `mix.exs` deps, add:

```elixir
      {:floki, "~> 0.36"},
```

Run: `mix deps.get`
Expected: floki fetched.

- [ ] **Step 2: Write failing tests for GoogleDoc parsing**

```elixir
defmodule RuleMaven.Games.GoogleDocTest do
  use ExUnit.Case, async: true
  alias RuleMaven.Games.GoogleDoc

  test "export_url derives the html export from an edit url" do
    assert GoogleDoc.export_url("https://docs.google.com/document/d/ABC123/edit#gid=0", "html") ==
             {:ok, "https://docs.google.com/document/d/ABC123/export?format=html"}
  end

  test "export_url rejects non-doc urls" do
    assert GoogleDoc.export_url("https://example.com/foo", "html") == :error
  end

  test "sections_from_html splits on headings" do
    html = """
    <html><body>
      <h1>Setup</h1><p>Place the board.</p>
      <h2>Combat</h2><p>Roll dice.</p><p>Compare values.</p>
    </body></html>
    """

    sections = GoogleDoc.sections_from_html(html)

    assert [%{label: "Setup", text: setup}, %{label: "Combat", text: combat}] = sections
    assert setup =~ "Place the board."
    assert combat =~ "Roll dice."
    assert combat =~ "Compare values."
  end

  test "sections_from_html keeps a preamble with nil label" do
    html = "<html><body><p>Intro text.</p><h1>A</h1><p>Body.</p></body></html>"
    sections = GoogleDoc.sections_from_html(html)
    assert [%{label: nil, text: intro} | _] = sections
    assert intro =~ "Intro text."
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/rule_maven/games/google_doc_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 4: Implement GoogleDoc**

```elixir
defmodule RuleMaven.Games.GoogleDoc do
  @moduledoc """
  Fetch + parse a public Google Doc used as a live rulebook source. Docs are
  fetched via the public `export?format=html` endpoint (no auth) and split into
  heading-anchored sections so a localized edit only churns its own section's
  chunks.
  """

  @doc_id_re ~r{docs\.google\.com/document/d/([A-Za-z0-9_-]+)}

  @doc "Derive the export URL for a given format from any Google Doc URL."
  def export_url(source_url, format) when is_binary(source_url) do
    case Regex.run(@doc_id_re, source_url) do
      [_, id] -> {:ok, "https://docs.google.com/document/d/#{id}/export?format=#{format}"}
      _ -> :error
    end
  end

  @doc "Fetch the HTML export of a public doc."
  def fetch_html(source_url) do
    with {:ok, url} <- export_url(source_url, "html"),
         {:ok, %Req.Response{status: 200, body: body}} <- Req.get(url, max_retries: 1) do
      {:ok, IO.iodata_to_binary(body)}
    else
      :error -> {:error, :not_a_google_doc}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Split exported HTML into heading-anchored sections. Content before the first
  heading becomes a section with `label: nil`. Heading text is the section label
  (used as `chunks.section_label`).
  """
  def sections_from_html(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("body")
    |> collect_nodes()
    |> group_by_heading()
    |> Enum.map(fn {label, texts} ->
      %{label: label, text: texts |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  # Flatten body children into an ordered list of {:heading, text} | {:text, text}.
  defp collect_nodes(body) do
    body
    |> Floki.children()
    |> Enum.flat_map(&node_to_item/1)
  end

  defp node_to_item({tag, _attrs, _children} = node) when tag in ~w(h1 h2 h3) do
    [{:heading, node |> Floki.text() |> String.trim()}]
  end

  defp node_to_item({_tag, _attrs, _children} = node) do
    text = node |> Floki.text() |> String.trim()
    if text == "", do: [], else: [{:text, text}]
  end

  defp node_to_item(_), do: []

  defp group_by_heading(items) do
    items
    |> Enum.reduce([{nil, []}], fn
      {:heading, label}, acc -> [{label, []} | acc]
      {:text, text}, [{label, texts} | rest] -> [{label, [text | texts]} | rest]
    end)
    |> Enum.reverse()
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/rule_maven/games/google_doc_test.exs`
Expected: PASS.

- [ ] **Step 6: Branch chunk_document on live_source**

In `chunk_document/1`, before the existing `pages = case doc.pages do ...` block, add a live-source branch that produces `chunks_with_meta` from sections instead of pages. The cleanest seam: compute `chunks_with_meta` differently when `doc.live_source and is_binary(doc.full_text)`.

Replace the `chunks_with_meta =` assignment with:

```elixir
    chunks_with_meta =
      if doc.live_source do
        live_chunks_with_meta(doc)
      else
        # (existing page-based builder, unchanged)
        pages
        |> Enum.flat_map(fn {page_num, page_text} ->
          page_text
          |> split_into_chunks(500)
          |> Enum.map(fn chunk_text ->
            %{content: "[Page #{page_num}]\n#{String.trim(chunk_text)}", page_number: page_num}
          end)
        end)
        |> Enum.with_index()
        |> Enum.map(fn {%{content: text, page_number: pn}, idx} ->
          section = detect_section_label(text)
          refs = detect_cross_references(text)
          {text, idx, section, refs, pn}
        end)
      end
```

And add the helper:

```elixir
  # Live Google Doc: full_text holds section-delimited text (one section per
  # \f, prefixed by "[Section: label]\n" — written by GoogleDocSyncWorker). We
  # sub-chunk within a section so an edit stays local, and carry the heading as
  # section_label. page_number is nil (living docs have no pages).
  defp live_chunks_with_meta(doc) do
    doc.full_text
    |> String.split("\f")
    |> Enum.flat_map(fn block ->
      {label, body} = split_section_block(block)

      body
      |> split_into_chunks(500)
      |> Enum.map(fn chunk_text -> {label, String.trim(chunk_text)} end)
    end)
    |> Enum.reject(fn {_label, text} -> text == "" end)
    |> Enum.with_index()
    |> Enum.map(fn {{label, text}, idx} ->
      refs = detect_cross_references(text)
      {text, idx, label, refs, nil}
    end)
  end

  defp split_section_block(block) do
    case Regex.run(~r/\A\[Section: (.*?)\]\n(.*)\z/s, block) do
      [_, label, body] -> {label, body}
      _ -> {nil, block}
    end
  end
```

- [ ] **Step 7: Write a failing test for the live branch**

Add to `test/rule_maven/games/reconcile_chunks_test.exs`:

```elixir
  test "live_source docs chunk by section and set section_label", %{} do
    {:ok, game} = Games.create_game(%{name: "Live", bgg_id: nil})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Living Rulebook",
        kind: "rulebook",
        live_source: true,
        full_text: "[Section: Setup]\nPlace the board.\f[Section: Combat]\nRoll dice.",
        status: "published"
      })

    {:ok, dirty} = Games.chunk_document(doc)
    labels = Repo.all(from c in Chunk, where: c.document_id == ^doc.id, select: c.section_label)

    assert dirty != []
    assert "Setup" in labels
    assert "Combat" in labels
  end
```

- [ ] **Step 8: Run tests**

Run: `mix test test/rule_maven/games/reconcile_chunks_test.exs test/rule_maven/games/google_doc_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add mix.exs mix.lock lib/rule_maven/games/google_doc.ex lib/rule_maven/games.ex test/rule_maven/games/google_doc_test.exs test/rule_maven/games/reconcile_chunks_test.exs
git commit -m "feat(rulebook): heading-anchored chunking for live Google Docs"
```

---

### Task 6: `GoogleDocSyncWorker` + daily cron

**Files:**
- Create: `lib/rule_maven/workers/google_doc_sync_worker.ex`
- Modify: `config/config.exs` (cron entry, ~line 57)
- Modify: `lib/rule_maven/games.ex` (add `sync_live_document/1` orchestrator + `list_live_documents/0`)
- Test: `test/rule_maven/workers/google_doc_sync_worker_test.exs`

**Interfaces:**
- Consumes: `GoogleDoc.fetch_html/1`, `GoogleDoc.sections_from_html/1` (Task 5), `chunk_document/1` (Task 2), `mark_stale_for_chunks/2` (Task 4), `documents.doc_content_hash/synced_at/live_source` (Task 3), `Jobs.start_run/4` + `Jobs.finish_run/3`.
- Produces:
  - `Games.list_live_documents/0 :: [Document.t()]` — all `live_source` published docs.
  - `Games.sync_live_document(doc) :: {:ok, :unchanged} | {:ok, {:synced, affected :: integer}} | {:error, term}` — fetch, hash-gate, rebuild `full_text` as section blocks, re-chunk, scoped-stale, update `doc_content_hash`/`synced_at`. Guards against empty fetch (never wipes chunks).

- [ ] **Step 1: Write the failing orchestrator test (with a stubbed fetch)**

The worker calls `Games.sync_live_document/1`. To keep the test offline, make `sync_live_document/1` accept the fetched HTML via an optional arg for testing: `sync_live_document(doc, html \\ :fetch)`. When `:fetch`, it calls `GoogleDoc.fetch_html/1`; a test passes HTML directly.

```elixir
defmodule RuleMaven.Games.SyncLiveDocumentTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.Chunk
  import Ecto.Query

  setup do
    {:ok, game} = Games.create_game(%{name: "Sync", bgg_id: nil})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Living Rulebook",
        kind: "rulebook",
        live_source: true,
        source_url: "https://docs.google.com/document/d/ABC/edit",
        status: "published"
      })

    %{game: game, doc: doc}
  end

  @html_v1 "<body><h1>Setup</h1><p>Place the board.</p><h2>Combat</h2><p>Roll dice.</p></body>"
  @html_v2 "<body><h1>Setup</h1><p>Place the board.</p><h2>Combat</h2><p>Roll dice and MOVE.</p></body>"

  test "first sync ingests and records the doc hash", %{doc: doc} do
    assert {:ok, {:synced, _}} = Games.sync_live_document(doc, @html_v1)
    doc = Games.get_document!(doc.id)
    assert is_binary(doc.doc_content_hash)
    assert doc.synced_at
    assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) > 0
  end

  test "unchanged doc is a no-op", %{doc: doc} do
    {:ok, {:synced, _}} = Games.sync_live_document(doc, @html_v1)
    doc = Games.get_document!(doc.id)
    assert {:ok, :unchanged} = Games.sync_live_document(doc, @html_v1)
  end

  test "edit stales only affected answers", %{game: game, doc: doc} do
    {:ok, {:synced, _}} = Games.sync_live_document(doc, @html_v1)

    setup_chunk =
      Repo.one(from c in Chunk, where: c.document_id == ^doc.id and c.section_label == "Setup")

    combat_chunk =
      Repo.one(from c in Chunk, where: c.document_id == ^doc.id and c.section_label == "Combat")

    warm = insert_pooled_answer(game.id, [setup_chunk.id])
    hit = insert_pooled_answer(game.id, [combat_chunk.id])

    doc = Games.get_document!(doc.id)
    assert {:ok, {:synced, affected}} = Games.sync_live_document(doc, @html_v2)
    assert affected >= 1

    assert Repo.reload(warm).stale == false
    assert Repo.reload(hit).stale == true
  end

  test "empty fetch never wipes chunks", %{doc: doc} do
    {:ok, {:synced, _}} = Games.sync_live_document(doc, @html_v1)
    before = Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count)
    doc = Games.get_document!(doc.id)
    assert {:error, :empty_fetch} = Games.sync_live_document(doc, "<body></body>")
    assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) == before
  end

  defp insert_pooled_answer(game_id, chunk_ids) do
    %RuleMaven.Games.QuestionLog{}
    |> RuleMaven.Games.QuestionLog.changeset(%{
      game_id: game_id,
      question: "q",
      answer: "a",
      pooled: true,
      stale: false,
      visibility: "community",
      source_chunk_ids: chunk_ids
    })
    |> Repo.insert!()
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/rule_maven/games/sync_live_document_test.exs`
Expected: FAIL — `sync_live_document/2` undefined.

- [ ] **Step 3: Implement the orchestrator**

In `lib/rule_maven/games.ex`:

```elixir
  @doc "All published live-source documents (daily sync targets)."
  def list_live_documents do
    Repo.all(from d in Document, where: d.live_source == true and d.status == "published")
  end

  @doc """
  Sync one live Google Doc: fetch its HTML export (or use the passed HTML in
  tests), hash-gate against `doc_content_hash`, and on change rebuild the
  section-delimited `full_text`, reconcile chunks, and stale only the answers
  citing changed chunks. Never wipes chunks on an empty/failed fetch.
  """
  def sync_live_document(%Document{} = doc, html_or_fetch \\ :fetch) do
    with {:ok, html} <- resolve_html(doc, html_or_fetch),
         sections = RuleMaven.Games.GoogleDoc.sections_from_html(html),
         :ok <- ensure_nonempty(sections) do
      full_text = sections_to_full_text(sections)
      new_hash = chunk_content_hash(full_text)

      if new_hash == doc.doc_content_hash do
        {:ok, :unchanged}
      else
        {:ok, doc} =
          update_document(doc, %{full_text: full_text}, chunk: false)

        {:ok, dirty_ids} = chunk_document(doc)
        affected = mark_stale_for_chunks(doc.game_id, dirty_ids)

        {:ok, _} =
          update_document(doc, %{doc_content_hash: new_hash, synced_at: DateTime.utc_now() |> DateTime.truncate(:second)}, chunk: false)

        {:ok, {:synced, affected}}
      end
    end
  end

  defp resolve_html(doc, :fetch), do: RuleMaven.Games.GoogleDoc.fetch_html(doc.source_url)
  defp resolve_html(_doc, html) when is_binary(html), do: {:ok, html}

  defp ensure_nonempty(sections) do
    total = sections |> Enum.map(&String.length(&1.text)) |> Enum.sum()
    if total < 20, do: {:error, :empty_fetch}, else: :ok
  end

  defp sections_to_full_text(sections) do
    sections
    |> Enum.map(fn
      %{label: nil, text: text} -> text
      %{label: label, text: text} -> "[Section: #{label}]\n#{text}"
    end)
    |> Enum.join("\f")
  end
```

Note: this relies on `update_document/2,3` accepting a `chunk: false` opt (it already does — `games.ex:983` reads `Keyword.get(opts, :chunk, true)`). Passing `chunk: false` here avoids a double re-chunk; we call `chunk_document/1` explicitly to capture `dirty_ids`.

- [ ] **Step 4: Run the orchestrator tests**

Run: `mix test test/rule_maven/games/sync_live_document_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the worker**

```elixir
defmodule RuleMaven.Workers.GoogleDocSyncWorker do
  @moduledoc """
  Daily: re-sync every live-source Google Doc rulebook. Fetches the public HTML
  export, hash-gates for changes, and on change re-chunks + stales only the
  answers citing changed chunks. Reports to the unified Jobs log.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias RuleMaven.{Games, Jobs}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id}) do
    run = Jobs.start_run("gdoc_sync", {"system", 0}, "Sync live Google Doc rulebooks", oban_job_id: oban_id)

    results =
      Games.list_live_documents()
      |> Enum.map(fn doc ->
        case Games.sync_live_document(doc) do
          {:ok, :unchanged} -> {doc.label, "unchanged"}
          {:ok, {:synced, n}} -> {doc.label, "synced (#{n} answers staled)"}
          {:error, reason} -> {doc.label, "error: #{inspect(reason)}"}
        end
      end)

    summary =
      case results do
        [] -> "No live documents."
        _ -> Enum.map_join(results, "; ", fn {label, status} -> "#{label}: #{status}" end)
      end

    Jobs.finish_run(run, "done", summary)
    :ok
  end
end
```

- [ ] **Step 6: Add the cron entry**

In `config/config.exs`, add to the `crontab:` list (after `JobLogPruneWorker`):

```elixir
       # Daily: re-sync live Google Doc rulebooks (fetch, hash-gate, scoped stale).
       {"30 4 * * *", RuleMaven.Workers.GoogleDocSyncWorker}
```

- [ ] **Step 7: Write a worker smoke test**

```elixir
defmodule RuleMaven.Workers.GoogleDocSyncWorkerTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Workers.GoogleDocSyncWorker

  test "perform runs with no live documents" do
    assert :ok = perform_job(GoogleDocSyncWorker, %{})
  end
end
```

(Uses `Oban.Testing` `perform_job/2`; confirm `use RuleMaven.DataCase` pulls in Oban testing helpers, else add `use Oban.Testing, repo: RuleMaven.Repo`.)

- [ ] **Step 8: Run tests**

Run: `mix test test/rule_maven/workers/google_doc_sync_worker_test.exs test/rule_maven/games/sync_live_document_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven/workers/google_doc_sync_worker.ex lib/rule_maven/games.ex config/config.exs test/rule_maven/workers/google_doc_sync_worker_test.exs test/rule_maven/games/sync_live_document_test.exs
git commit -m "feat(rulebook): daily GoogleDocSyncWorker + scoped re-sync orchestrator"
```

---

### Task 7: Admin attach flow, manual re-sync, "updated {date}" label

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex` (attach-live-doc form + "Re-sync now" button + handlers)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (user-facing "Rulebook updated {date}" label)
- Test: `test/rule_maven_web/live/game_live/live_doc_test.exs`

**Interfaces:**
- Consumes: `Games.create_document/1`, `Games.sync_live_document/1`, `Games.list_live_documents/0`, `documents.synced_at`.
- Produces: LiveView events `"attach_live_doc"` (params `%{"source_url" => url}`) and `"resync_live_doc"` (params `%{"id" => doc_id}`).

**Attach flow:** owner/admin pastes the public doc URL → validate via `GoogleDoc.export_url/2` → `create_document(%{live_source: true, source_url: url, kind: "rulebook", status: "published", game_id: ...})` → immediate `sync_live_document/1` for the first snapshot (run async via `start_async` so the LiveView doesn't block — background-work-durable rule).

- [ ] **Step 1: Write a failing LiveView test**

```elixir
defmodule RuleMavenWeb.GameLive.LiveDocTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias RuleMaven.Games

  setup :register_and_log_in_admin  # existing helper; if absent, use the project's admin login helper

  test "attaching a live doc validates the url", %{conn: conn} do
    {:ok, game} = Games.create_game(%{name: "AttachTest", bgg_id: nil})

    {:ok, view, _html} = live(conn, ~p"/games/#{game}/prepare")

    render_submit(element(view, "#attach-live-doc-form"), %{
      "source_url" => "https://example.com/not-a-doc"
    })

    assert render(view) =~ "not a Google Doc"
  end
end
```

(Adjust the route/selector to the project's actual prepare page. If `register_and_log_in_admin` differs, use the existing admin-login test helper — grep `test/support/conn_case.ex`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live/live_doc_test.exs`
Expected: FAIL — form/handler absent.

- [ ] **Step 3: Add the attach form + handlers**

In `prepare.ex`, add a form and `handle_event`s (place the tool `handle_event` clauses beside the page's first `handle_event`, per the sub-bar convention). The `attach_live_doc` handler validates then creates + kicks an async first sync:

```elixir
  def handle_event("attach_live_doc", %{"source_url" => url}, socket) do
    case RuleMaven.Games.GoogleDoc.export_url(url, "html") do
      {:ok, _} ->
        {:ok, doc} =
          Games.create_document(%{
            game_id: socket.assigns.game.id,
            label: "Living Rulebook",
            kind: "rulebook",
            live_source: true,
            source_url: url,
            status: "published"
          })

        {:noreply,
         socket
         |> put_flash(:info, "Live rulebook attached — syncing…")
         |> start_async({:sync_live_doc, doc.id}, fn -> Games.sync_live_document(doc) end)}

      :error ->
        {:noreply, put_flash(socket, :error, "That URL is not a Google Doc.")}
    end
  end

  def handle_event("resync_live_doc", %{"id" => id}, socket) do
    doc = Games.get_document!(id)
    {:noreply, start_async(socket, {:sync_live_doc, doc.id}, fn -> Games.sync_live_document(doc) end)}
  end

  def handle_async({:sync_live_doc, _id}, {:ok, result}, socket) do
    msg =
      case result do
        {:ok, :unchanged} -> "Rulebook already up to date."
        {:ok, {:synced, n}} -> "Rulebook synced — #{n} answers refreshed."
        {:error, reason} -> "Sync failed: #{inspect(reason)}"
      end

    {:noreply, put_flash(socket, :info, msg)}
  end
```

Add the form markup in the prepare template (a single URL input + submit `#attach-live-doc-form` → `attach_live_doc`, and a "Re-sync now" button → `resync_live_doc` with `phx-value-id`). Use existing `btn-*` classes (button-system rule).

- [ ] **Step 4: Add the user-facing label**

In `show.ex`'s template, where the rulebook source is shown, add (only when `doc.live_source and doc.synced_at`):

```heex
<span class="text-sm text-muted">Rulebook updated {Calendar.strftime(@doc.synced_at, "%b %-d, %Y")}</span>
```

- [ ] **Step 5: Run tests**

Run: `mix test test/rule_maven_web/live/game_live/live_doc_test.exs`
Expected: PASS.

- [ ] **Step 6: Update /help + tours**

Per help-tours-upkeep rule: add a short "Living rulebook (Google Doc)" entry to the help page describing attach + auto-daily-sync + manual re-sync. (Find the help content file: `grep -rn "def help\|/help" lib/rule_maven_web`.)

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/prepare.ex lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/live_doc_test.exs
git commit -m "feat(rulebook): attach live Google Doc + manual re-sync + updated-date label"
```

---

## Verification (whole feature)

- [ ] Run the full set of touched test files:

```
mix test test/rule_maven/games/chunk_test.exs test/rule_maven/games/document_test.exs test/rule_maven/games/reconcile_chunks_test.exs test/rule_maven/games/mark_stale_for_chunks_test.exs test/rule_maven/games/google_doc_test.exs test/rule_maven/games/sync_live_document_test.exs test/rule_maven/workers/google_doc_sync_worker_test.exs test/rule_maven_web/live/game_live/live_doc_test.exs
```

- [ ] Manual smoke (major-behavior verification per verify-major-only rule): attach a real public Google Doc to a test game on the prepare page, confirm chunks + embeddings appear, edit one section of the doc, run the worker (`GoogleDocSyncWorker.new(%{}) |> Oban.insert()` in an IEx console), and confirm only that section's answers went stale.
