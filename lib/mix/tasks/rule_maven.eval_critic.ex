defmodule Mix.Tasks.RuleMaven.EvalCritic do
  @shortdoc "Grades the grounding critic's hallucination detection, per model"

  @moduledoc """
  The critic is a SAFETY component, so it cannot be graded by the answer eval.

      mix rule_maven.eval_critic Catan
      mix rule_maven.eval_critic Catan --model google/gemini-2.5-flash-lite --runs 3

  `mix rule_maven.eval` scores the answers a pipeline produces. It cannot score
  the critic, because the critic only does anything when an answer is WRONG — and
  a probe set of good answers gives it nothing to catch. A cheaper critic would
  score 100% there while quietly catching nothing, which is the exact failure a
  cost optimization is most likely to cause and least likely to notice.

  So this feeds the critic answers whose grounding is known in advance, against
  the real rulebook chunks, and measures the two error directions separately:

    * MISS  — a hallucinated answer waved through as grounded. The dangerous one:
              a fabrication reaches the player and the pool.
    * FALSE ALARM — a grounded answer flagged as hallucinated. Cheaper, but not
              free: it buys a corrective retry and can end in a refusal of a
              question the rulebook actually answers.

  A model may only replace the critic if it MISSES no more than the incumbent.
  Being cheaper is not a defense.
  """

  use Mix.Task

  import Ecto.Query

  alias RuleMaven.{Games, LLM, Repo}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [model: :string, runs: :integer])

    game_name = List.first(args) || Mix.raise("usage: mix rule_maven.eval_critic <game name>")
    runs = opts[:runs] || 1

    game =
      Repo.one(from g in Games.Game, where: g.name == ^game_name) ||
        Mix.raise("no game named #{inspect(game_name)}")

    model = opts[:model] || LLM.model(:cheap)
    Mix.shell().info("critic model: #{model}  (#{runs} run(s))")

    sources = corpus_texts(game)

    if sources == [], do: Mix.raise("#{game_name} has no published chunks")

    results =
      for _run <- 1..runs, c <- cases() do
        verdict = judge(c, sources, game, model)
        Map.put(c, :got, verdict)
      end

    report(results, runs, model)
  end

  defp corpus_texts(game) do
    Repo.all(
      from c in Games.Chunk,
        join: d in Games.Document,
        on: d.id == c.document_id,
        where: d.game_id == ^game.id and d.status == "published",
        order_by: [asc: c.document_id, asc: c.id],
        select: c.content
    )
  end

  defp judge(c, sources, game, model) do
    case LLM.critique_grounding(c.quotes, c.answer,
           sources: sources,
           cacheable_sources: true,
           model: model,
           game_id: game.id
         ) do
      {:ok, %{verdict: v}} -> v
      {:error, _} -> :error
    end
  end

  # Grounded cases are drawn from what the Catan rulebook actually says.
  # Hallucinated ones are the failure shapes seen in real answers: a plausible
  # invented quantity, a polarity inversion (saying yes to what the rule forbids),
  # and a rule imported from a different game.
  defp cases do
    [
      %{
        id: "grounded_discard",
        expect: :grounded,
        quotes: ["you must discard half of your Resource Cards"],
        answer: "If you have more than 7 resource cards when a 7 is rolled, you discard half of them, rounded down."
      },
      %{
        id: "grounded_longest_road",
        expect: :grounded,
        quotes: ["Longest Road"],
        answer: "The Longest Road card is worth 2 victory points, and another player can take it from you by building a longer road."
      },
      %{
        id: "grounded_robber_desert",
        expect: :grounded,
        quotes: ["The robber begins the game in the desert"],
        answer: "The robber starts in the desert hex at the beginning of the game."
      },
      %{
        id: "hallucinated_invented_number",
        expect: :hallucinated,
        quotes: ["you must discard half of your Resource Cards"],
        answer: "When a 7 is rolled you must discard exactly 3 resource cards, no matter how many you hold."
      },
      %{
        id: "hallucinated_invented_rule",
        expect: :hallucinated,
        quotes: ["Longest Road"],
        answer: "The Longest Road card is worth 2 victory points, and it also lets you take one free resource card from the bank on each of your turns."
      },
      %{
        id: "hallucinated_foreign_rule",
        expect: :hallucinated,
        quotes: ["The robber begins the game in the desert"],
        answer: "The robber begins in the desert, and any player may pay 2 gold to move it at the start of their turn."
      },
      %{
        # The polarity inversion. Decided in code before the critic ever runs
        # (Citations.contradicted_quote/2) precisely BECAUSE the critic cannot see
        # it — reproduced 3/3 returning "grounded". Kept here to keep that fact
        # honest: if a model ever does catch it, that is worth knowing, and if the
        # incumbent still misses it, this documents why the code guard exists.
        id: "inversion_known_critic_blindspot",
        expect: :hallucinated,
        quotes: ["A player may not trade with other players on another player's turn"],
        answer: "**Yes**, you may trade with other players during another player's turn."
      }
    ]
  end

  defp report(results, runs, model) do
    shell = Mix.shell()
    shell.info("\n" <> String.duplicate("-", 74))

    grouped = Enum.group_by(results, & &1.id)

    for {id, rs} <- grouped do
      [%{expect: expect} | _] = rs
      ok = Enum.count(rs, &(&1.got == expect))
      got = rs |> Enum.map(& &1.got) |> Enum.frequencies() |> inspect()
      mark = if ok == runs, do: "ok  ", else: "MISS"

      shell.info("#{mark} #{String.pad_trailing(id, 34)} #{ok}/#{runs}  #{got}")
    end

    halluc = Enum.filter(results, &(&1.expect == :hallucinated))
    grounded = Enum.filter(results, &(&1.expect == :grounded))

    misses = Enum.count(halluc, &(&1.got != :hallucinated))
    false_alarms = Enum.count(grounded, &(&1.got != :grounded))

    shell.info(String.duplicate("-", 74))
    shell.info("model: #{model}")

    shell.info(
      "MISSES (hallucination waved through): #{misses}/#{length(halluc)} " <>
        "— the dangerous direction"
    )

    shell.info("FALSE ALARMS (good answer flagged): #{false_alarms}/#{length(grounded)}")
    shell.info("\nA cheaper critic may only ship if MISSES do not rise.")
  end
end
