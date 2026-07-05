# Rule Maven

Ask board game rules questions in plain English, get answers grounded in the
actual rulebook text — right at the table.

Rule Maven is a Phoenix LiveView web app (installable as a PWA) built for
settling rules disputes mid-game. Pick your game (and any expansions in
play), type your question, and get a cited answer pulled from the rulebook —
no more digging through a 40-page PDF.

## Features

- **Grounded Q&A** — answers cite the source rulebook text, not just LLM guesswork
- **Multi-source games** — handles core rulebooks, expansions, FAQs, and errata as separate authoritative sources
- **Expansion-aware** — answers adapt to which expansions you actually have on the table
- **Rulebook ingestion** — upload a PDF, it's chunked, embedded, and made searchable
- **PWA** — installable on mobile, usable at the table without a laptop
- **Persona voices** — fun answer restyling (optional, cached)
- **Admin tooling** — moderation dashboard, audit log, cost/quota controls, job monitoring

## Tech Stack

- Elixir + Phoenix 1.8 + LiveView
- Ecto + PostgreSQL with `pgvector` for embedding similarity search
- Oban for background jobs (ingestion, extraction, embedding)
- LLM access via OpenAI-compatible API (OpenRouter, Groq, Gemini, Ollama)

## Setup

```bash
mix setup          # deps.get + ecto.create + ecto.migrate + seeds
mix phx.server      # or: iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000).

## Development

```bash
mix format && mix credo --strict && mix test   # full pre-commit check
```

See `AGENTS.md` and `.agents/` for architecture, conventions, and data flow docs.
