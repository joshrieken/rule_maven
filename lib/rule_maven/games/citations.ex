defmodule RuleMaven.Games.Citations do
  @moduledoc """
  Validates that an answer's citation is actually grounded in the source text it
  was generated from, rather than merely present.

  `valid?/3` checks a cited passage / page against the retrieval context (the
  `[Page N]`-prefixed chunk strings the LLM was given). A citation is valid when:

    * every claim it makes is grounded — a long-enough cited passage must appear
      in some source chunk, and a cited page must match a page present in the
      chunks; AND
    * at least one claim is positively grounded.

  This catches a hallucinated quote even when the page number happens to be
  right, and a fabricated page even when no checkable passage is given. Short,
  unverifiable passages don't *fail* validation — they just can't ground it on
  their own, so a valid page is then required.
  """

  # Passages shorter than this (normalized) are too generic to verify reliably.
  @min_needle_len 12

  @doc "True if the citation is grounded in `source_chunks` (a list of strings)."
  def valid?(passage, cited_page, source_chunks) do
    valid?(passage, cited_page, source_chunks, nil)
  end

  @doc """
  Like `valid?/3`, but when `cited_source` matches a chunk's `label`
  (case-insensitive), grounding is checked against that source's chunks only.
  A `nil` or unmatched label falls back to the pooled behavior (all chunks).

  `source_chunks` accepts either a list of `%{label:, content:}` maps or plain
  strings (wrapped as `%{label: nil, content: s}` for backward compatibility).
  """
  def valid?(passage, cited_page, source_chunks, cited_source) do
    maps = to_chunk_maps(source_chunks)
    scoped = scope_chunks(maps, cited_source)

    texts = Enum.map(scoped, & &1.content)
    chunks = normalize_chunks(texts)
    has_passage = is_binary(passage) and String.trim(passage) != ""
    has_page = is_integer(cited_page)

    needle = passage_needle(passage)
    checkable_passage = has_passage and String.length(needle) >= @min_needle_len
    passage_match = checkable_passage and Enum.any?(chunks, &String.contains?(&1, needle))
    passage_bad = checkable_passage and not passage_match

    page_match = has_page and cited_page in chunk_pages(texts)
    page_bad = has_page and not page_match

    grounded = passage_match or page_match

    grounded and not passage_bad and not page_bad
  end

  @doc """
  Normalizes a model-reported `cited_source` string against the actual
  `source_chunks` labels before it's persisted or rendered. Matching is
  case-insensitive; a match returns the chunk's CANONICAL label (its stored
  casing), not the model's raw string. A `nil` cited_source, or one that
  doesn't match any known label (a hallucinated source name), returns `nil` —
  callers should fall back to a generic label (e.g. "Rulebook") in that case.
  """
  def canonical_source(nil, _source_chunks), do: nil

  def canonical_source(cited_source, source_chunks) when is_binary(cited_source) do
    target = String.downcase(cited_source)

    source_chunks
    |> to_chunk_maps()
    |> Enum.find(&(String.downcase(&1.label || "") == target))
    |> case do
      %{label: label} when is_binary(label) -> label
      _ -> nil
    end
  end

  def canonical_source(_cited_source, _source_chunks), do: nil

  defp to_chunk_maps(chunks) when is_list(chunks) do
    Enum.flat_map(chunks, fn
      %{content: _} = chunk -> [Map.put_new(chunk, :label, nil)]
      s when is_binary(s) -> [%{label: nil, content: s}]
      _ -> []
    end)
  end

  defp to_chunk_maps(_), do: []

  defp scope_chunks(chunks, nil), do: chunks

  defp scope_chunks(chunks, cited_source) when is_binary(cited_source) do
    target = String.downcase(cited_source)

    case Enum.filter(chunks, &(String.downcase(&1.label || "") == target)) do
      [] -> chunks
      scoped -> scoped
    end
  end

  defp scope_chunks(chunks, _), do: chunks

  defp passage_needle(passage) when is_binary(passage) do
    passage
    |> normalize()
    |> String.split(" ", trim: true)
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp passage_needle(_), do: ""

  defp normalize_chunks(chunks) when is_list(chunks),
    do: chunks |> Enum.filter(&is_binary/1) |> Enum.map(&normalize/1)

  defp normalize_chunks(_), do: []

  defp chunk_pages(chunks) when is_list(chunks) do
    chunks
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn text ->
      Regex.scan(~r/\[Page\s+(\d+)\]/i, text, capture: :all_but_first)
    end)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
  end

  defp chunk_pages(_), do: []

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\[page\s*\d+\]/i, " ")
    |> String.replace(~r/[^a-z0-9 ]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
