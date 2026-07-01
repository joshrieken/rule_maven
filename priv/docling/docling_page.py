#!/usr/bin/env python3
"""Docling page reader — the local layout-model lane for the extraction spike.

Reads ONE page of a PDF with Docling's layout + table-structure models and
emits reading-order Markdown on stdout. This is the candidate "reader_a" the
gate would cross-check against cheap vision: layout-aware, local, no per-page
API cost.

Contract (kept dead simple so the Elixir side treats it like pdftotext/tesseract):
  in : --pdf PATH --page N   (N is 1-based, matching pdftoppm/pdftotext)
  out: Markdown on stdout, exit 0
  err: message on stderr, non-zero exit (missing dep, bad page, convert failure)

Setup lives in priv/docling/README.md. If Docling isn't importable we exit 3
with an actionable message so the mix task can tell the operator how to install.
"""
import argparse
import sys


def eprint(*a):
    print(*a, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf", required=True)
    ap.add_argument("--page", type=int, required=True)
    args = ap.parse_args()

    if args.page < 1:
        eprint("page must be >= 1 (1-based)")
        return 2

    try:
        from docling.document_converter import DocumentConverter
    except Exception as e:  # ImportError or a broken torch install
        eprint(
            "docling not importable: %s\n"
            "Set up the sidecar venv — see priv/docling/README.md" % e
        )
        return 3

    try:
        conv = DocumentConverter()
        # page_range is inclusive and 1-based in Docling — read just this sheet
        # so we pay layout inference for one page, not the whole rulebook.
        result = conv.convert(args.pdf, page_range=(args.page, args.page))
        md = result.document.export_to_markdown()
    except Exception as e:
        eprint("convert failed: %s" % e)
        return 1

    sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
