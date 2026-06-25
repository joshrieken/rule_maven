# Design Doc — Rule Maven

> Written before implementation. Must be reviewed and signed off
> before changes begin.

---

## Decisions

**D1 — OpenRouter as primary API gateway** for both chat and embeddings.
Single API key, 200+ models, OpenAI-compatible endpoints (same shape
code already uses). Free tier low-volume, pay-as-you-go above.
One integration, not three.

**D2 — pgvector for embedding storage.** No separate service.
Same Postgres, same Ecto pool. Cosine distance + HNSW index =
sub-10ms search at scale. Tradeoffs documented above.

**D3 — Oban for background jobs.** FAQ clustering (nightly) +
cheatsheet generation. Reliable scheduling, idempotent retries,
observability. Standard Phoenix pattern.

**D4 — FAQ-only instant answers.** Raw Q&A log not surfaced to
users — feeds clustering/curation only. Published FAQ entries sole
cache-hit path. Prevents wrong uncurated answers.

**D5 — Conditional admin review** for uploaded documents.
Auto-publish docs that extract cleanly (no OCR fallback, text stats
healthy). Flag for review when OCR used or extraction garbled.
Admin can spot-check auto-published docs anytime.

**D6 — Document versioning.** New editions/errata create new document
version, not silent overwrite. Prevents mixed old+new rules
in retrieval.

**D7 — Auto-approve high-confidence FAQ drafts.** FAQ drafts where
all source Q&As have thumbs-up (or no feedback but high consistency)
skip admin review, auto-publish. Flag for review when: answers
disagree, any source thumbs-down, or cluster new + small.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    LiveView (Browser)                    │
├───────────────┬──────────────────┬──────────────────────┤
│  Game List    │  Ask Screen      │  Settings/Admin       │
│  + Import     │  (chat-style)    │  (review, FAQ, etc.)  │
└───────┬───────┴────────┬─────────┴──────┬───────────────┘
        │                │                │
        ▼                ▼                ▼
┌─────────────────────────────────────────────────────────┐
│                   Context Layer                         │
│  RuleMaven.Games    RuleMaven.Faq    RuleMaven.Embed    │
│  RuleMaven.Docs     RuleMaven.LLM    RuleMaven.Users    │
└──────────────────────────┬──────────────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │PostgreSQL│ │ OpenRouter│ │  Oban    │
        │+pgvector │ │   API     │ │  Jobs    │
        └──────────┘ └──────────┘ └──────────┘
```

**Provider abstraction layer:**

Current code has 3 providers (Groq, Gemini, Ollama). Add OpenRouter as
**default**, keep others as configurable fallbacks. OpenRouter handles both:

- `POST /api/v1/chat/completions` — LLM chat
  (supports Claude, GPT, Llama, Gemini, etc.)
- `POST /api/v1/embeddings` — embeddings (text-embedding-3-small, etc.)

Provider selection lives in DB settings (`llm_provider`, `embedding_provider`).
Both default to `"openrouter"`.

---

## Player UX — What the User Sees

Design constraint: **used one-handed at game table on phone.**
Everything thumb-reachable. No multi-step workflows, no dense tables,
no tiny tap targets.

### Screen: Game List

```
┌──────────────────────────┐
│  Rule Maven             │
├──────────────────────────┤
│  🔍 Search games...      │
│                          │
│  ┌────────────────────┐  │
│  │ 🎲 Wingspan        │  │  ← tap to open
│  │    12 Q&As · 4 FAQ │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │ 🎲 Root            │  │
│  │    31 Q&As · 9 FAQ │  │
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │ 🎲 Cascadia        │  │
│  │    New! 0 Q&As     │  │
│  └────────────────────┘  │
└──────────────────────────┘
```

Each game card shows Q&A + FAQ counts — signals how well-covered game is.

### Screen: Ask (the one that matters)

```
┌──────────────────────────┐
│ ←  Wingspan              │
├──────────────────────────┤
│                          │
│  ┌────────────────────┐  │
│  │ PREVIOUS (scroll)  │  │  ← scroll up to see session history
│  │                    │  │
│  │ Q: Can I play two  │  │
│  │ birds in one turn?  │  │
│  │                    │  │
│  │ A: No. Each player │  │
│  │ takes exactly one  │  │
│  │ action per turn.   │  │
│  │ ▸ "On your turn,   │  │
│  │   you may take ONE │  │
│  │   of the following │  │
│  │   actions..." p.4  │  │
│  │          👍  👎    │  │
│  └────────────────────┘  │
│                          │
│  ┌────────────────────┐  │
│  │ ▸ "Each player     │  │  ← FAQ answer (visually distinct)
│  │   takes one action │  │
│  │   per turn..."     │  │
│  │          ✅ FAQ    │  │     ← badge shows it's cached
│  └────────────────────┘  │
│                          │
│  ┌──────────────────────┐│
│  │ Ask a rules question ││  ← text input, always at bottom
│  │ ...                  ││
│  └──────────────────────┘│
│         [Ask]            │  ← big button, thumb-reachable
└──────────────────────────┘
```

### Interaction: Asking a Question

```
TAP [Ask]
  │
  ├─► Input clears, question appears in chat with spinner
  │   ┌────────────────────┐
  │   │ Q: Can I cache     │
  │   │ food on other      │
  │   │ players' birds? ⏳ │  ← spinner
  │   └────────────────────┘
  │
  ├─► FAQ HIT (cos ≥ 0.92, ~10ms)
  │   ┌────────────────────┐
  │   │ A: No. Food goes   │
  │   │ on your own birds. │
  │   │          ✅ FAQ    │  ← green badge, instant
  │   └────────────────────┘
  │
  └─► FAQ MISS → LLM (~2s)
      ┌────────────────────┐
      │ A: Food must be    │
      │ cached on your own │
      │ player mat. Other  │
      │ players' birds are │
      │ not valid targets. │
      │ ▸ "Cached food is  │  ← citation block
      │   placed on your   │
      │   player mat..."   │
      │          👍  👎    │  ← feedback buttons
      └────────────────────┘
```

**FAQ hit vs LLM answer:**

| Signal | FAQ hit | LLM answer |
|---|---|---|
| Latency | Instant (<50ms), no spinner | ~1-2s, spinner then fade-in |
| Badge | `✅ FAQ` (green) | No badge |
| Citation | Shown (from FAQ's source) | Shown |
| Feedback | None — already vetted | 👍 👎 appear |

### Interaction: Thumbs Up/Down

- After LLM answer, 👍 👎 appear inline below answer
- Tap one → registers feedback, both buttons dim (can't change)
- Feedback writes to `questions_log.feedback = 'up' | 'down'`
- Thumbs-down flags Q&A for admin review
- FAQ entries never show feedback buttons (already approved)

### Evolution: Cold Start → Mature FAQ

**Game just added, zero FAQ entries:**

```
Q: Can I play two birds?
   ↓ ~2s LLM call
A: [LLM answer with citation]
   👍 👎
```

Every question costs LLM call.

**After a week, FAQ building:**

```
Q: Can I play two birds?
   ↓ ~2s LLM call (first time)
A: [answer] 👍 👎

Q: Can I play two birds?  ← someone else asks same thing
   ↓ INSTANT, FAQ hit
A: [same answer] ✅ FAQ
```

Auto-promotion after 3+ upvotes.

**Mature game, 10+ FAQ entries:**

```
Most common questions → instant FAQ answers
Weird edge cases → LLM (but those are rare)
```

Experience gets faster with use — network effect for household game library.

### Mobile-First Details

- Text input pinned to bottom of viewport, never scrolls away
- [Ask] button large (min 48px), thumb-reachable
- Previous Q&As scroll above input; newest answer auto-scrolls into view
- No horizontal scroll — all content wraps
- FAQ badge and citation block are only visual chrome
  (no "thinking..." text, no token counts)
- Answer takes >5s → show "Still looking..." to prevent re-tap
- Rate limit warning: "Daily limit reached. Ask your game master to
  increase it." — not hard error

---

## Data Model (Updated)

### New tables

```sql
-- faq_entries: admin-approved canonical Q&A pairs,
-- checked first on every question
CREATE TABLE faq_entries (
  id              BIGSERIAL PRIMARY KEY,
  game_id         BIGINT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  canonical_question TEXT NOT NULL,
  canonical_answer   TEXT NOT NULL,
  -- for similarity matching, dimension depends on model
  question_embedding  VECTOR(768),
  -- array of questions_log.id, traceability
  source_qa_ids   BIGINT[] NOT NULL,
  -- 'draft' | 'published' | 'discarded'
  status          TEXT NOT NULL DEFAULT 'draft',
  -- true if auto-published without admin review
  auto_approved   BOOLEAN NOT NULL DEFAULT false,
  -- e.g. "3 upvotes, no disagreements, score=5"
  auto_approve_reason TEXT,
  approved_by     BIGINT REFERENCES users(id),
  approved_at     TIMESTAMPTZ,
  inserted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_faq_entries_game ON faq_entries(game_id);
CREATE INDEX idx_faq_entries_status ON faq_entries(status);
-- HNSW index for similarity search (created after data exists)
CREATE INDEX idx_faq_entries_embedding
  ON faq_entries
  USING hnsw (question_embedding vector_cosine_ops);
```

### Modified tables

```diff
-- documents (was rulebook_sources — renamed for clarity)
ALTER TABLE rulebook_sources RENAME TO documents;
ALTER TABLE documents
+ ADD COLUMN version       INTEGER NOT NULL DEFAULT 1,
+ -- cached LLM-generated cheatsheet
+ ADD COLUMN cheatsheet    TEXT,
+ -- 'pending_review' | 'published'
+ ADD COLUMN status        TEXT NOT NULL DEFAULT 'pending_review',
+ -- SHA256 of original file, for dedup
+ ADD COLUMN file_hash     TEXT,
+ ADD COLUMN reviewed_by   BIGINT REFERENCES users(id),
+ ADD COLUMN reviewed_at   TIMESTAMPTZ;

-- chunks (was rulebook_chunks)
ALTER TABLE rulebook_chunks RENAME TO chunks;
ALTER TABLE chunks
+ RENAME COLUMN source_id TO document_id,
+ -- embedding of chunk.content
+ ADD COLUMN embedding     VECTOR(768),
+ -- e.g. "Section 3.2 — Combat"
+ ADD COLUMN section_label TEXT;
-- Drop game_id from chunks (denormalize via document)
ALTER TABLE chunks DROP COLUMN game_id;

CREATE INDEX idx_chunks_embedding
  ON chunks
  USING hnsw (embedding vector_cosine_ops);

-- questions_log (name stays, add columns)
ALTER TABLE questions_log
+ ADD COLUMN question_embedding  VECTOR(768),
+ -- which chunks were retrieved for this answer
+ ADD COLUMN source_chunk_ids    BIGINT[],
+ -- 'up' | 'down' | null
+ ADD COLUMN feedback            TEXT,
+ -- assigned by clustering job
+ ADD COLUMN cluster_id          BIGINT,
+ -- which document version was used
+ ADD COLUMN document_id         BIGINT REFERENCES documents(id);
```

### Unchanged tables

- **games** — no changes needed
- **users** — no changes needed
- **app_settings** — no changes needed
- **llm_logs** — no changes needed

### Settings additions (stored in app_settings)

- `embedding_provider` = `"openrouter"` — Provider for embedding API
- `embedding_model` = `"openai/text-embedding-3-small"`
  — Embedding model (768-dim)
- `faq_similarity_threshold` = `"0.92"` — Cosine floor for FAQ cache hit
- `chunk_similarity_threshold` = `"0.78"` — Floor for retrieval chunk inclusion
- `cluster_similarity_threshold` = `"0.85"` — Floor for question clustering
- `retrieval_top_k` = `"6"` — Max chunks per question
- `chunk_size_tokens` = `"400"` — Target tokens per chunk
- `chunk_overlap_tokens` = `"50"` — Overlap between chunks
- `auto_approve_documents` = `"true"` — Auto-publish clean doc uploads
- `auto_approve_faqs` = `"true"` — Auto-publish high-confidence FAQ drafts

---

## Workflows (Detailed)

### 1. Admin Upload & Indexing

```
POST upload PDF
  │
  ├─► Validate file type (PDF only), check file_hash
  │   against existing documents
  │   └─► Duplicate? Reject with message:
  │       "This file was already uploaded as {title} v{version}"
  │
  ├─► Extract text: pdftotext → plain text (existing pipeline)
  │
  ├─► Split into chunks: by section heading where possible
  │   (regex on "Section \d+", "Chapter \d+", etc.)
  │   otherwise ~400 tokens with ~50 token overlap.
  │   Store section_label metadata per chunk.
  │
  ├─► Generate embeddings: for each chunk, call OpenRouter
  │   embeddings API (batch where possible). Store
  │   (content, embedding, section_label) in chunks table.
  │
  ├─► Generate cheatsheet: one LLM call over full extracted
  │   text → cheatsheet markdown. Store on
  │   documents.cheatsheet. (CheatSheet module, adapted.)
  │
  └─► Document status = 'pending_review'. Admin reviews:
        - Extracted text preview (side-by-side with original if possible)
        - Chunk quality (spot-check a few)
        - Cheatsheet preview
        - Metadata (title, version, edition tag)
      Admin approves → status = 'published'
```

**Cheatsheet generation moves to Oban job**
(currently uses `Task.async` + polling via Settings — move to
proper job queue).

**Chunking logic** (new, replaces current `\n\n`-based split):

```elixir
# Rough sketch, not final code
def chunk_text(text, opts \\ []) do
  token_size = opts[:token_size] || 400
  overlap = opts[:overlap] || 50
  
  sections = split_by_headings(text)  # try structural first
  if length(sections) > 1 do
    sections  # keep section boundaries
  else
    # fallback to sliding window
    split_by_token_window(text, token_size, overlap)
  end
end
```

### 2. Question & Answer

```
User asks question (scoped to game_id)
  │
  ├─► Embed the question (OpenRouter embeddings API)
  │
  ├─► Step 1: Check published FAQ entries
  │   └─► Cosine similarity against
  │       faq_entries.question_embedding
  │       (WHERE game_id=?, status='published')
  │       └─► Match above threshold (0.92)?
  │           → Return canonical_answer instantly. No LLM call.
  │
  ├─► Step 2: Retrieve relevant chunks
  │   └─► Cosine similarity against chunks.embedding
  │       (JOIN documents WHERE game_id=?
  │        AND status='published')
  │       └─► Top-k (default 6) chunks.
  │           If none above threshold (0.78),
  │           use fallback ordering.
  │
  ├─► Step 3: Call LLM (OpenRouter chat completions)
  │   └─► System prompt with game name + retrieved chunks as context
  │       └─► Model: configurable
  │           (default: anthropic/claude-3.5-haiku
  │            for speed/cost)
  │
  ├─► Step 4: Parse response (answer + citation)
  │   └─► Existing ---CITATION--- delimiter parsing
  │
  └─► Step 5: Save to questions_log
      └─► Store: question, question_embedding, answer,
          source_chunk_ids, document_id, provider, model
      └─► feedback = null (user can tap thumbs up/down later)
```

**Cache hit breakdown:**

| Check | Latency | Cost | Confidence |
|---|---|---|---|
| FAQ match (cos ≥ 0.92) | ~2ms (DB) | $0 | High — admin-approved |
| Retrieval + LLM | ~2s | ~$0.002 | Medium — LLM-grounded in chunks |
| Fallback (no good chunks) | ~2s | ~$0.005 | Low — LLM with weak context |

### 3. FAQ Extraction & Curation

**Trigger:** Nightly Oban job (or manual "run curation now" from admin UI).

```
Oban job: FaqClusterWorker
  │
  ├─► 1. Fetch unclustered questions_log
  │   (cluster_id IS NULL, game_id scoped)
  │
  ├─► 2. For each question, compare against ALL
  │   existing clusters for that game
  │   └─► Cosine similarity question_embedding vs
  │       cluster centroid (mean of member embeddings)
  │       └─► Above threshold (0.85)? Add to existing cluster.
  │       └─► Below threshold? Create new cluster.
  │   └─► Update questions_log.cluster_id for each question
  │
  ├─► 3. Sort clusters by size (frequency) — busiest topics first
  │
  ├─► 4. For clusters without a published FAQ entry:
  │   └─► If size ≥ 2: draft a faq_entries row
  │       └─► Call LLM: given the clustered questions
  │           + their answers, produce:
  │           - canonical_question (one clear formulation)
  │           - canonical_answer
  │             (reconciled from all answers in cluster)
  │           - If answers in cluster disagree
  │             → flag explicitly in draft notes
  │       └─► Embed the canonical_question
  │       └─► Score the draft (see Automation Tiers above)
  │           ├─► Score ≥ 4 → auto-publish
  │           │   (status = 'published', auto_approved = true)
  │           └─► Score < 4 → status = 'draft', flag for review
  │       └─► source_qa_ids = [all qa_log ids in this cluster]
  │   └─► If size = 1: skip (not enough signal)
  │
  └─► 5. Notify admin: "N auto-published, M need review" (dashboard badge)
```

**Admin curation UI** (new LiveView — only shows items needing review):

- Dashboard: auto-published count + "needs review" count,
  per game
- Review list: draft FAQ entries below auto-publish threshold
- Each draft shows: canonical question, canonical answer,
  flag reason, score breakdown, source Q&A pairs (expandable)
- Actions: **Approve** (→ published), **Edit & Approve**,
  **Merge** (with another draft), **Discard**
- Demote: admin can demote any auto-published entry back to
  draft with one click

---

## Automation Tiers — Minimizing Admin Work

Goal: admin only touches uncertain things. Everything else self-serves.

### Document Upload → Auto-Publish vs Review

```
Upload PDF
  │
  ├─► Extract text (pdftotext)
  │
  ├─► Quality check:
  │   ├─► OCR fallback was needed? → FLAG FOR REVIEW (garbled text likely)
  │   ├─► Text < 500 chars? → FLAG FOR REVIEW (empty/broken PDF)
  │   ├─► Garbled ratio > 20%? → FLAG FOR REVIEW
  │   │   (high non-dictionary words, weird chars)
  │   └─► Otherwise → AUTO-PUBLISH
  │       (status = 'published', skip review gate)
  │
  └─► Admin dashboard badge: "N auto-published, M need review"
      Admin can drill into auto-published docs anytime to spot-check.
```

**Settings toggle:** `auto_approve_documents` (default: `true`).
Admin can disable to review everything.

### FAQ Draft → Auto-Publish vs Review

```
Oban cluster job produces FAQ draft
  │
  ├─► Score the draft:
  │   ├─► All source Q&As have thumbs-up? → score += 3
  │   ├─► Any source Q&A has thumbs-down? → FLAG FOR REVIEW
  │   ├─► Answers in cluster disagree
  │   │   (LLM flagged discrepancy)? → FLAG FOR REVIEW
  │   ├─► Cluster size ≥ 3? → score += 2
  │   ├─► Cluster size = 2? → score += 1
  │   └─► Source Q&As all from different users? → score += 1
  │
  ├─► Score ≥ 4 → AUTO-PUBLISH
  │   (status = 'published')
  │   Score < 4 → FLAG FOR REVIEW
  │   (status = 'draft')
  │
  └─► Admin dashboard badge: "N auto-published FAQs, M need review"
```

**Settings toggle:** `auto_approve_faqs` (default: `true`).

### Direct Promotion — Bypass Clustering Entirely

Single Q&A pair with **3+ thumbs-up** skips clustering Oban job.
Nightly `DirectPromotionWorker` promotes these directly to
`faq_entries` with `status = 'published'`.

```
Nightly Oban: DirectPromotionWorker
  │
  ├─► Find questions_log rows WHERE feedback = 'up',
  │   not yet linked to any faq_entry
  ├─► Group by (game_id, question_embedding similarity ≥ 0.92)
  ├─► Groups with ≥ 3 upvotes → auto-create faq_entry (published)
  └─► Groups with 1-2 upvotes → feed into normal clustering job
```

### Admin Still Sees Everything

- Dashboard: "Auto-published this week"
  (collapsed by default), "Needs review" (prominent)
- Every auto-decision logged with reason
  (e.g. "Auto-published: clean extraction,
  98% dictionary words")
- Admin can **demote** auto-published FAQ back to draft with one click
- Audit trail: `faq_entries.auto_approved` boolean
  + `auto_approve_reason` text field

### End State: Near-Zero-Touch

Mature game (10+ FAQ entries) is almost entirely self-serve:

- New user question matches FAQ → Nothing (instant answer)
- New user question misses FAQ, gets LLM answer, gets upvoted →
  Nothing (feeds future clustering)
- Same question gets upvoted 3+ times → Nothing (auto-promoted
  overnight)
- OCR-garbled PDF uploaded → Review prompt in dashboard
- FAQ cluster has conflicting answers → Review prompt in dashboard
- Someone downvotes an answer → Review prompt in dashboard

Only bottom 3 rows ever need admin attention.

---

## Migration Plan

**Phase 0: Dependencies & infrastructure**
(non-destructive, runs alongside existing code)
1. Add `{:pgvector, "~> 0.3"}` to mix.exs
2. Add `{:oban, "~> 2.18"}` to mix.exs
3. Run `CREATE EXTENSION IF NOT EXISTS vector` on dev/test/prod databases
4. Add Oban migration + config

**Phase 1: Schema evolution** (additive only, existing data preserved)
1. Rename `rulebook_sources` → `documents`,
   add new columns (version, cheatsheet, status,
   file_hash, reviewed_by, reviewed_at)
2. Rename `rulebook_chunks` → `chunks`,
   add embedding + section_label,
   rename source_id → document_id
3. Add columns to `questions_log`
   (question_embedding, source_chunk_ids,
   feedback, cluster_id, document_id)
4. Create `faq_entries` table
5. Add HNSW indexes on `chunks.embedding` and `faq_entries.question_embedding`

**Phase 2: Backfill** (batch job, runs incrementally)
1. Existing published documents: set `status = 'published'`, `version = 1`
2. Existing chunks: generate embeddings via OpenRouter, store in new column
3. Existing question_logs: backfill question_embeddings where possible

**Phase 3: New functionality**
1. Embedding context module (`RuleMaven.Embed`)
2. FAQ context module (`RuleMaven.Faq`)
3. Updated RAG retrieval (semantic via pgvector, replaces keyword-overlap)
4. Oban workers: FaqClusterWorker, CheatSheetWorker
5. Admin review UI
6. FAQ curation UI
7. Thumbs up/down on Q&A (LiveView event)

**Phase 4: Cleanup**
1. Remove old keyword-overlap retrieval code
2. Drop deprecated columns if any

---

## Module Map (New + Modified)

```
lib/rule_maven/
  embed.ex              # NEW — embedding API client (OpenRouter embeddings endpoint)
  llm.ex                # MODIFIED — add OpenRouter as default provider
  faq.ex                # NEW — FAQ CRUD, similarity search, approval workflow
  documents.ex          # NEW/RENAMED — document CRUD, chunking, review workflow
  games.ex              # MODIFIED — delegate chunking to documents.ex, add FAQ-aware ask
  cheat_sheet.ex         # MODIFIED — use Oban job instead of Task.async+Settings polling

lib/rule_maven/games/
  game.ex               # UNCHANGED
  document.ex           # RENAMED from rulebook_source.ex, with new fields
  chunk.ex              # RENAMED from rulebook_chunk.ex, with embedding + section_label
  question_log.ex       # MODIFIED — add embedding, chunk_ids, feedback, cluster_id, document_id

  faq_entry.ex          # NEW — faq_entries schema

lib/rule_maven/workers/
  faq_cluster_worker.ex     # NEW — nightly clustering Oban job
  direct_promotion_worker.ex # NEW — auto-promote highly-upvoted Q&As to FAQ
  cheat_sheet_worker.ex     # NEW — Oban job for cheatsheet generation

lib/rule_maven_web/live/
  game_live/
    show.ex             # MODIFIED — thumbs up/down, FAQ-aware caching
    form.ex             # MODIFIED — document upload triggers new pipeline
    review.ex           # NEW — admin document review UI
  faq_live/
    index.ex            # NEW — FAQ curation list (admin)
    edit.ex             # NEW — FAQ draft review/edit/approve (admin)
```

---

## Open Questions (Resolved)

**Q1 — Embedding provider?** OpenRouter, model
`openai/text-embedding-3-small` (768-dim). Configurable in settings.

**Q2 — pgvector or no?** Yes. Tradeoffs documented above (Decision D2).

**Q3 — Background jobs?** Oban (Decision D3).

**Q4 — Raw log matches surfaced?** No — FAQ-only instant answers
(Decision D4).

**Q5 — LLM providers?** OpenRouter as default.
Keep Groq/Gemini/Ollama as configurable fallbacks.

**Q6 — Admin review?** Full review UI (Decision D5).

**Q7 — Anthropic Claude?** Available through OpenRouter as
`anthropic/claude-3.5-haiku` or similar. Default configurable.

## Open Questions (Still Open)

**OQ1 — Embedding dimension mismatch:** what if user switches
embedding model (e.g., from 768-dim to 1536-dim)? All stored
vectors become invalid. Options:
(a) forbid switching after data exists,
(b) backfill job,
(c) store dimension in settings and validate at query time.
Recommend (a) for v1 — put warning in settings UI.

**OQ2 — Document dedup:** hash raw PDF file bytes (SHA256) or
extracted text? File bytes catches exact duplicate uploads.
Text hash catches "same content, different file."
Recommend file bytes for simplicity — exact duplicates only.

**OQ3 — Cheatsheet format:** current code renders to PDF via
Puppeteer. Keep PDF or switch to rendered markdown in UI?
Keep PDF for now (existing pipeline).
Add optional markdown view later.

**OQ4 — Should embeddings be re-generated** when document text
changes (edit/re-upload)? Yes. Trigger re-chunk + re-embed
on document edit. Make explicit in admin review UI.

**OQ5 — OpenRouter free tier limits?** Document actual limits
observed. Fallback to direct Groq/Gemini if OpenRouter
rate-limited. Already works with existing multi-provider
retry logic.

---

## Implementation Phases (Time-Ordered)

### Phase 0 — Infra (1 PR)

- Add pgvector + Oban deps
- Enable pgvector extension
- Configure Oban (migration + config)

### Phase 1 — Schema (1 PR)

- All migrations (rename tables, add columns, create faq_entries)
- Updated schemas
- No behavior changes yet — old code still works against renamed tables

### Phase 2 — Embeddings (1 PR)

- `RuleMaven.Embed` module (OpenRouter embeddings API)
- Embedding generation for chunks (on document publish)
- Embedding generation for questions (on ask)
- pgvector similarity search replaces keyword-overlap in `retrieve_chunks`
- Backfill rake task for existing data

### Phase 3 — FAQ Pipeline (1 PR)

- `RuleMaven.Faq` context
- FAQ similarity check in ask flow (cache layer 1)
- Oban workers: FaqClusterWorker (nightly clustering),
  DirectPromotionWorker (auto-promote upvoted Q&As)
- FAQ draft generation via LLM with auto-publish scoring
- Admin dashboard: auto-published vs needs-review counts

### Phase 4 — Admin UIs (1 PR)

- Document review page
- FAQ curation pages
- Thumbs up/down on Q&A
- Dashboard stats (cache hit rate, etc.)

### Phase 5 — Polish & Cleanup (1 PR)

- Remove old keyword-overlap code
- Cheatsheet generation → Oban
- Provider fallback improvements
- PWA finalization (if not already done)

---

## Sign-off

Review decisions, data model, workflows, and open questions above.
Once signed off, implementation begins in phase order.

- [ ] Decisions (D1–D7) approved
- [ ] Data model changes approved  
- [ ] Workflow details approved
- [ ] Migration plan approved
- [ ] Phasing approved

Signed: _______________ Date: _______________