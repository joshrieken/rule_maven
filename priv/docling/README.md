# Docling sidecar (extraction reader spike)

Local PDF layout model evaluated as a third **reader lane** for the extraction
gate. Goal: a layout-aware, local, per-page-free `reader_a` that agrees with
cheap vision more often than dumb `pdftotext` does — every extra agreement is
one fewer costly `escalate_page` call. See `mix docling_ab`.

## Why a Python sidecar

Docling is PyTorch + layout/table models — no Elixir equivalent. Same pattern as
the existing `pdftoppm`/`tesseract` shell-outs: the app calls `docling_page.py`
as a subprocess and reads Markdown off stdout.

## Setup (one time)

Docling has no wheels for Python 3.14 yet — use 3.11:

```bash
cd priv/docling
/opt/homebrew/bin/python3.11 -m venv .venv
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt
```

First `convert` downloads model weights (hundreds of MB) — one-time.

## Smoke test

```bash
.venv/bin/python docling_page.py \
  --pdf ../static/uploads/rulebooks/1782695559504_SummerCampInstructions.pdf \
  --page 1
```

Should print Markdown for page 1. Exit codes: `0` ok, `1` convert failed,
`2` bad args, `3` docling not installed.

## Run the A/B

From project root, with the venv built:

```bash
DOCLING_PYTHON=priv/docling/.venv/bin/python \
  mix docling_ab --pdf priv/static/uploads/rulebooks/1782695559504_SummerCampInstructions.pdf --pages 1,5,9
```

It scores, per page, `Gate.assess(docling, vision)` vs the current
`Gate.assess(pdftotext, vision)` and reports the escalation-rate delta.
