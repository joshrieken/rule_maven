defmodule RuleMaven.LLM.Savings do
  @moduledoc """
  Append-only ledger of estimated/real LLM cost savings.

  Three kinds:
    * "cache_hit"    — a pool hit avoided a whole LLM ask. Real avoidance, the
                       amount is estimated from recent real usage.
    * "prompt_cache" — provider billed cached input tokens at a lower rate. Real
                       discount.
    * "cheap_route"  — an op ran on a cheap model instead of the answer model.
                       Counterfactual; never summed into the headline total.

  Writes are best-effort: a ledger failure must never break the request path.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

  alias RuleMaven.Repo

  # Cold-start fallback per operation: {prompt_tokens, completion_tokens}.
  @fallback_tokens %{"ask" => {4000, 300}}
  @default_fallback {2000, 200}
  @window 50
  @min_same_game 3

  @kinds ~w(cache_hit prompt_cache cheap_route)
  @headline_kinds ~w(cache_hit prompt_cache)

  schema "llm_savings" do
    field :kind, :string
    field :operation, :string
    field :estimated_tokens, :integer, default: 0
    field :estimated_usd, :float, default: 0.0
    field :model, :string
    field :game_id, :id
    field :user_id, :id

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc "Best-effort insert of a savings row. Always returns :ok."
  def record(kind, attrs) when kind in @kinds do
    attrs = Map.put(attrs, :kind, kind)

    %__MODULE__{}
    |> cast(attrs, [:kind, :operation, :estimated_tokens, :estimated_usd, :model, :game_id, :user_id])
    |> validate_required([:kind])
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.warning("Savings.record failed: #{inspect(cs.errors)}"); :ok
    end
  rescue
    e -> Logger.warning("Savings.record raised: #{inspect(e)}"); :ok
  end

  def record(_kind, _attrs), do: :ok

  @doc "Estimates and records the savings from a cache/pool hit avoiding a call."
  def record_cache_hit(operation, game_id, user_id) do
    est = estimate_avoided(operation, game_id)

    record("cache_hit", %{
      operation: operation,
      estimated_tokens: est.tokens,
      estimated_usd: est.usd,
      model: est.model,
      game_id: game_id,
      user_id: user_id
    })
  rescue
    e -> Logger.warning("Savings.record_cache_hit raised: #{inspect(e)}"); :ok
  end

  @doc """
  Savings roll-up for the last `days` days. `headline_*` count only real-
  avoidance/real-discount kinds (cache_hit, prompt_cache); cheap_route is
  reported in `by_kind` but excluded from the headline.
  """
  def summary(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    by_kind =
      Repo.all(
        from s in __MODULE__,
          where: s.inserted_at >= ^since,
          group_by: s.kind,
          select: {s.kind, sum(s.estimated_tokens), sum(s.estimated_usd)}
      )
      # `* 1.0` coerces a possible %Decimal{} from the SQL sum() into a float.
      |> Enum.map(fn {k, t, u} -> %{kind: k, tokens: t || 0, usd: (u || 0.0) * 1.0} end)

    headline = Enum.filter(by_kind, &(&1.kind in @headline_kinds))

    %{
      days: days,
      headline_usd: Enum.reduce(headline, 0.0, &(&1.usd + &2)),
      headline_tokens: Enum.reduce(headline, 0, &(&1.tokens + &2)),
      by_kind: by_kind
    }
  end

  @doc """
  Estimates the tokens/USD a now-avoided call of `operation` would have cost,
  from the average of recent real `LLM.Log` rows (preferring `game_id`). Falls
  back to a per-operation constant when there is no usable history.
  """
  def estimate_avoided(operation, game_id) do
    model = RuleMaven.LLM.model()
    rows = recent_logs(operation, game_id)

    rows = if game_id && length(rows) < @min_same_game, do: recent_logs(operation, nil), else: rows

    {p, c} =
      case rows do
        [] ->
          Map.get(@fallback_tokens, operation, @default_fallback)

        _ ->
          {avg(rows, & &1.prompt_tokens), avg(rows, & &1.completion_tokens)}
      end

    %{tokens: p + c, usd: RuleMaven.LLM.Pricing.cost(model, p, c), model: model}
  end

  defp recent_logs(operation, game_id) do
    base =
      from l in RuleMaven.LLM.Log,
        where: l.operation == ^operation and l.success == true,
        order_by: [desc: l.inserted_at],
        limit: @window

    base = if game_id, do: where(base, [l], l.game_id == ^game_id), else: base
    Repo.all(base)
  end

  defp avg(rows, fun) do
    vals = rows |> Enum.map(fun) |> Enum.map(&(&1 || 0))
    div(Enum.sum(vals), length(vals))
  end
end
