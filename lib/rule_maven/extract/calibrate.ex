defmodule RuleMaven.Extract.Calibrate do
  @moduledoc """
  Calibration loop for the escalation gate — lowers the *cost* of accuracy over
  time without ever lowering accuracy.

  Every escalation logs its gate signals and whether the strong re-read actually
  changed the answer. Two uses:

    * **Waste measurement** — the fraction of escalations where the strong model
      did NOT materially differ from the cheap read is wasted spend. A high,
      stable waste rate for a feature region means those pages could stop
      escalating. (We surface the metric; we do **not** auto-tighten the gate —
      under the accuracy-first mandate, blindly skipping a page is the one move
      that could lose accuracy, so threshold changes stay evidence-gated.)
    * **Drift detection** — a small random fraction of *agreed* pages are
      escalated anyway and logged, so we keep verifying the gate's "two readers
      agree = ceiling" assumption against ground truth instead of trusting it
      forever.

  All logging is best-effort: a telemetry write must never fail an extraction.
  """
  import Ecto.Query

  alias RuleMaven.Extract.Calibration
  alias RuleMaven.Repo

  # Token-set agreement at/above this → the strong read said essentially the same
  # thing as the cheap read, so the escalation didn't change the answer (wasted).
  @materially_differs_below 0.85
  @default_drift_rate 0.05

  @doc """
  Should this agreed page be drift-sampled (escalated + logged anyway)? Reads
  `extract_drift_sample_rate` (0.0–1.0), default 0.05. Prefer `should_sample?/1`
  in a per-page loop and read the rate once via `drift_rate/0`, to avoid a
  Settings (DB) read per page.
  """
  def drift_sample?, do: should_sample?(drift_rate())

  @doc "Random draw against a pre-read rate — no Settings read."
  def should_sample?(rate) when is_number(rate), do: :rand.uniform() < rate

  @doc "Configured drift-sample rate (0.0–1.0), read once per extraction."
  def drift_rate do
    case RuleMaven.Settings.get("extract_drift_sample_rate") do
      v when is_binary(v) and v != "" ->
        case Float.parse(v) do
          {f, _} when f >= 0.0 and f <= 1.0 -> f
          _ -> @default_drift_rate
        end

      _ ->
        @default_drift_rate
    end
  end

  @doc """
  Was the strong re-read materially different from the cheap candidate? True when
  their token-set agreement is below the threshold (so the escalation earned its
  cost). Used by the logger and exposed for callers.
  """
  def materially_differed?(jaccard) when is_number(jaccard),
    do: jaccard < @materially_differs_below

  @doc """
  Records one escalation outcome. Best-effort — returns `:ok` and swallows any
  error so telemetry can never break extraction. `attrs` keys match the schema
  fields (agreement, coverage, cheap_wordish, cheap_tokens, strong_tokens,
  jaccard_strong_cheap, materially_differed, drift_sample).
  """
  def log(attrs) do
    %Calibration{}
    |> Ecto.Changeset.cast(attrs, [
      :agreement,
      :coverage,
      :cheap_wordish,
      :cheap_tokens,
      :strong_tokens,
      :jaccard_strong_cheap,
      :materially_differed,
      :drift_sample
    ])
    |> Repo.insert()

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Escalation waste rate over the last `days`: the fraction of (non-drift)
  escalations where the strong model did not materially differ from the cheap
  read. High → the gate is escalating pages it didn't need to; that headroom can
  be reclaimed (evidence for a future, carefully-gated threshold change). Returns
  a float 0.0–1.0, or nil when there's no data yet.
  """
  def waste_rate(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    q =
      from c in Calibration,
        where:
          c.inserted_at >= ^since and c.drift_sample == false and
            not is_nil(c.materially_differed),
        select:
          {count(c.id), sum(fragment("CASE WHEN ? THEN 0 ELSE 1 END", c.materially_differed))}

    case Repo.one(q) do
      {total, wasted} when is_integer(total) and total > 0 -> (wasted || 0) / total
      _ -> nil
    end
  end

  @doc """
  Drift signal over the last `days`: the fraction of drift-sampled (agreed) pages
  where the strong read materially differed. Should stay LOW — a rising value
  means the gate's "agreement = ceiling" assumption is degrading and the agree
  threshold may be too loose. Returns a float, or nil when no samples yet.
  """
  def drift_rate_observed(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    q =
      from c in Calibration,
        where:
          c.inserted_at >= ^since and c.drift_sample == true and
            not is_nil(c.materially_differed),
        select:
          {count(c.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.materially_differed))}

    case Repo.one(q) do
      {total, differed} when is_integer(total) and total > 0 -> (differed || 0) / total
      _ -> nil
    end
  end
end
