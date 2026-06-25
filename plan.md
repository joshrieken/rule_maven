# Rule Maven — Build Plan

## What this is

A small Phoenix LiveView app (installable as a PWA) that answers board game
rules questions at the table. Pick a game, ask a question in plain English,
get an answer grounded in that game's actual rulebook text, with the source
passage shown so the table can sanity-check it.

This is a personal/friend-group tool, not a public product. Optimize for
"works great for the games we own" over generality.

## Goals (MVP)

1. Add a game with its rulebook text (paste or upload).
2. Pick a game at the table, type/ask a question, get an answer.
3. Every answer cites the specific rulebook passage it's based on.
4. If the rulebook doesn't clearly cover the question, say so — never guess
   confidently.

## Non-goals (for now)

- No multi-tenant / multi-user accounts. Single household or friend-group use.
- No vector DB / RAG pipeline. Rulebooks are short enough (20–60 pages) to
  put the full text directly into the model's context per request. This
  avoids retrieval quality issues and is simpler to build and debug.
- No native iOS/Android app. A LiveView PWA installs to the home screen and
  is enough for "phone at the table" use.
- No automatic rulebook scraping/ingestion pipeline in v1 — text goes in
  manually (paste/upload) per game.

## Tech stack

- **Backend/UI**: Phoenix + LiveView (Elixir)
- **DB**: Postgres
- **LLM**: Anthropic Claude API (messages endpoint) or preferably some good free option
- **PWA**: manifest.json + service worker for "Add to Home Screen", no native
  shell needed
- **Voice input (stretch)**: Web Speech API in the browser, no extra backend
  work

## Data model

```sql
-- games being tracked
create table games (
  id bigserial primary key,
  name text not null,
  bgg_id integer,              -- optional, for later integration with her app
  inserted_at timestamp not null default now()
);

-- rulebook text per game (could have multiple sources: base rules, FAQ, errata)
create table rulebook_sources (
  id bigserial primary key,
  game_id bigint not null references games(id),
  label text not null,          -- e.g. "Core Rulebook", "Official FAQ", "House Rules"
  full_text text not null,      -- raw extracted text
  inserted_at timestamp not null default now()
);

-- log of questions asked, for review / spotting commonly confusing rules
create table questions_log (
  id bigserial primary key,
  game_id bigint not null references games(id),
  question text not null,
  answer text not null,
  cited_passage text,
  inserted_at timestamp not null default now()
);
```

## Claude API integration

Single call per question. Build the system prompt per request by
concatenating the relevant `rulebook_sources.full_text` for the selected
game (base rules + FAQ + house rules, if present).

System prompt template:

```
You are a rules assistant for the board game "{game_name}".

Below is the full text of the rulebook (and FAQ/errata if provided).
Answer the user's question using ONLY this text.

Rules:
- Always quote or closely paraphrase the specific passage you're basing
  your answer on. Include a reference to where it appears (section/page
  if available).
- If the rulebook does not clearly address the question, say so plainly
  instead of guessing or inferring an answer. It's better to say "the
  rules don't cover this directly" than to invent a ruling.
- Be concise. This is being read at a table mid-game.

RULEBOOK TEXT:
{full_text}
```

User message: the raw question, e.g. "Can I cast two reaction spells in
the same combat round?"

Response handling:

- Display the answer text.
- Display the cited passage in a visually distinct block (e.g. a quote
  card) so it's easy to double check.
- Log question + answer + cited passage to `questions_log`.

## UI/UX flow (LiveView)

**Screen 1 — Game list**

- List of games with rulebooks loaded.
- "Add game" button → Screen 2.

**Screen 2 — Add/edit game**

- Game name input.
- One or more rulebook source blocks: label + paste-text textarea (or file
  upload that extracts text server-side — see note below on PDF handling).
- Save.

**Screen 3 — Ask screen (the one that matters at the table)**

- Game name header.
- Simple chat-style input: type question, hit ask.
- Answer renders below with the cited passage highlighted.
- Previous Q&A in this session listed above (scroll up), so the table can
  see earlier answers without re-asking.
- (Stretch) mic button for voice input via Web Speech API, transcribes to
  the text input.

## PDF/text ingestion note

For official PDF rulebooks, extract text server-side on upload (e.g. via
a PDF text extraction library available in the Elixir ecosystem, or shell
out to a CLI tool) and store the extracted plain text in `full_text`.
For scanned/older rulebooks without clean text, paste manually for v1 —
OCR can be a stretch goal.

## Implementation phases

**Phase 1 — Skeleton**

- Phoenix app scaffolded, Postgres schema migrated.
- Game CRUD (list, add, edit) with plain-text rulebook paste only (no PDF
  upload yet).

**Phase 2 — Core Q&A**

- Ask screen wired to Claude API using the system prompt template above.
- Display answer + cited passage.
- Log to `questions_log`.

**Phase 3 — PWA polish**

- manifest.json, service worker, icons so it installs to home screen.
- Mobile-friendly LiveView layout (this is used one-handed at a table).

**Phase 4 — Stretch**

- PDF upload with server-side text extraction.
- Voice input.
- "House rules" override source per game, layered on top of official rules
  in the prompt.
- Pull game list from girlfriend's collection app via API instead of
  manual entry.

## Open questions to resolve during build

- Single shared instance for the household, or basic auth/login at all?
  (Leaning: no auth needed for v1, it's running for just you two.)
- Where does this get hosted — same infra as other personal projects, or
  a small standalone deploy (e.g. Fly.io)?
- Claude model choice: start with a fast/cheap model for cost given this
  is mid-game and low-stakes; revisit if answer quality on edge-case rules
  questions isn't good enough.
