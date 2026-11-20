defmodule RuleMaven.Workers.SymbolKeyWorker do
  @moduledoc """
  Durable in-app generation of a game's symbol key (`RuleMaven.Symbols`),
  run only from a human-started Prepare. Candidate tokens are extracted in
  code first: a book with none is marked "no symbols" without any LLM call.
  The model may only name tokens from that list, and every kept token is
  re-checked against the book text. Text-only — icon crops are hand-made.

  Broadcasts `{:symbols_ready, game_id}` on `topic/1`. `unique` per game, a
  no-op in test where Oban isn't supervised.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, LLM, Symbols}

  def topic(game_id), do: "symbols:#{game_id}"

  @doc "Enqueue symbol-key generation (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if Application.get_env(:rule_maven, Oban)[:testing] != :manual,
      do: %{game_id: game_id} |> new() |> Oban.insert(),
      else: :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("symbol_key", {"game", game_id}, "Symbol key — #{game.name}",
        oban_job_id: oban_id
      )

    case build(game) do
      {:ok, n} ->
        Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:symbols_ready, game_id})
        Jobs.finish_run(run, "done", if(n == 0, do: "No inline symbols.", else: "#{n} symbols."))
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  @doc "Builds and stores the key. Returns `{:ok, count}` or `{:error, reason}`."
  def build(game) do
    text = Games.document_full_text(game)

    case Symbols.candidate_tokens(text) do
      [] ->
        Symbols.mark_none(game.id, true)
        {:ok, 0}

      candidates ->
        with {:ok, entries} <- LLM.generate_symbol_key(game.name, text, candidates, game.id) do
          store_entries(game, text, entries)
        end
    end
  end

  defp store_entries(game, text, entries) do
    {found, _} = Symbols.tokens_in_text(Enum.map(entries, & &1.token), text)
    keep = MapSet.new(found)
    # A regenerate must not throw away hand-cropped icons: carry each
    # existing image over to the entry with the same token.
    images = Map.new(Symbols.list(game.id), &{&1.token, {&1.image_path, &1.image_note}})

    entries =
      for e <- entries, MapSet.member?(keep, e.token) do
        {path, note} = Map.get(images, e.token, {nil, nil})
        Map.merge(e, %{image_path: path, image_note: note})
      end

    with {:ok, _} <- Symbols.replace(game.id, entries, "llm") do
      Symbols.mark_none(game.id, entries == [])
      {:ok, length(entries)}
    end
  end
end
