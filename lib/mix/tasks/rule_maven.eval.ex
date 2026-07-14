defmodule Mix.Tasks.RuleMaven.Eval do
  @shortdoc "Replays a probe set against a game and grades correctness against cost"

  @moduledoc """
  The scoreboard for any change that trades accuracy for money.

      mix rule_maven.eval Catan
      mix rule_maven.eval Catan --runs 3
      mix rule_maven.eval Catan --critic-model google/gemini-2.5-flash-lite
      mix rule_maven.eval Catan --cheap-model google/gemini-2.5-flash-lite
      mix rule_maven.eval Catan --answer-model google/gemini-2.5-flash-lite

  Every cost optimization in this pipeline is really a bet that the cheaper path
  answers as well as the expensive one. That bet is untestable by eye — an answer
  that is fluent, cited, and WRONG looks exactly like one that is right — so this
  replays a fixed set of probes with known-correct answers (`priv/eval/<game>.exs`)
  and reports accuracy and spend side by side. A change that moves one without
  moving the other is the only kind worth shipping.

  Probes are graded on the answer text, plus refusal behavior: a probe marked
  `refuse: true` is genuinely uncovered by the rulebook, and answering it
  confidently is scored as a failure, not a success. Cheap models fail here first.

  Each probe runs with `skip_pool` and `skip_normalize` so it measures the ANSWER
  path, not the cache in front of it. `--runs N` repeats the whole set N times:
  these models are non-deterministic, and a single green run is not evidence a
  change is safe.

  Costs come from `llm_logs` rows written during the run and are discounted for
  cached input tokens, so the number is what the run actually cost, not list price.
  """

  use Mix.Task

  import Ecto.Query

  alias RuleMaven.{Games, LLM, Repo}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, args} =
      OptionParser.parse!(argv,
        strict: [
          runs: :integer,
          cheap_model: :string,
          critic_model: :string,
          answer_model: :string,
          set: :string
        ]
      )

    game_name = List.first(args) || Mix.raise("usage: mix rule_maven.eval <game name>")
    runs = opts[:runs] || 1

    game =
      Repo.one(from g in Games.Game, where: g.name == ^game_name) ||
        Mix.raise("no game named #{inspect(game_name)}")

    probes = load_probes(opts[:set] || String.downcase(game_name))

    apply_overrides(opts)

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    results =
      for run <- 1..runs, probe <- probes do
        Map.put(grade(probe, game), :run, run)
      end

    report(results, probes, runs, started_at)
  end

  defp load_probes(set) do
    path = Path.join([:code.priv_dir(:rule_maven), "eval", "#{set}.exs"])

    unless File.exists?(path), do: Mix.raise("no probe set at #{path}")

    {probes, _} = Code.eval_file(path)
    probes
  end

  # The overrides are the whole point: they let a candidate model be graded on the
  # same probes as the incumbent, in the same run, without editing settings that a
  # concurrent request would also see.
  defp apply_overrides(opts) do
    if m = opts[:cheap_model] do
      Application.put_env(:rule_maven, :eval_cheap_model, m)
      Mix.shell().info("cheap model override (critic, tiebreaker, classifiers): #{m}")
    end

    if m = opts[:critic_model] do
      Application.put_env(:rule_maven, :eval_critic_model, m)
      Mix.shell().info("critic model override: #{m}")
    end

    if m = opts[:answer_model] do
      Application.put_env(:rule_maven, :eval_answer_model, m)
      Mix.shell().info("answer model override: #{m}")
    end
  end

  defp grade(probe, game) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        LLM.ask(game, probe.q, [], [], skip_pool: true, skip_normalize: true)
      rescue
        e -> {:error, Exception.message(e)}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, res} ->
        answer = to_string(res[:answer])
        refused? = LLM.refusal_answer?(answer)

        {pass?, reason} = check(probe, answer, refused?)

        %{id: probe.id, pass: pass?, reason: reason, answer: answer, ms: elapsed}

      {:error, reason} ->
        %{id: probe.id, pass: false, reason: "error: #{inspect(reason)}", answer: "", ms: elapsed}
    end
  end

  # A refusal is graded, not skipped. Refusing a covered question and answering an
  # uncovered one are the two failures that matter most, and both hide behind a
  # naive substring check.
  defp check(%{refuse: true}, _answer, true), do: {true, "refused (correct)"}

  defp check(%{refuse: true}, _answer, false),
    do: {false, "ANSWERED an uncovered question — should have refused"}

  # `refuse_ok` is for BAIT: a question the rulebook does not answer, where a
  # refusal is fine but so is explicitly denying the premise ("there is no
  # maximum hand size"), which is the better answer of the two. Demanding a
  # refusal here would have scored a correct denial as a failure — it did, which
  # is why this clause exists. What is actually being graded is fabrication, via
  # must_not: inventing a number is the failure, staying silent is not.
  defp check(%{refuse_ok: true}, _answer, true), do: {true, "refused (acceptable)"}

  defp check(_probe, _answer, true), do: {false, "REFUSED a covered question"}

  defp check(probe, answer, false) do
    cond do
      probe[:must] && not Regex.match?(probe.must, answer) ->
        {false, "missing #{inspect(Regex.source(probe.must))}"}

      probe[:must_not] && Regex.match?(probe.must_not, answer) ->
        {false, "contains forbidden #{inspect(Regex.source(probe.must_not))}"}

      true ->
        {true, "ok"}
    end
  end

  defp report(results, probes, runs, started_at) do
    shell = Mix.shell()
    total = length(results)
    passed = Enum.count(results, & &1.pass)

    shell.info("\n" <> String.duplicate("-", 78))

    # Group by probe so a FLAKY probe (2/3 runs) is visible as flaky rather than
    # averaged into a number that looks like partial credit.
    for probe <- probes do
      runs_for = Enum.filter(results, &(&1.id == probe.id))
      ok = Enum.count(runs_for, & &1.pass)
      mark = if ok == runs, do: "PASS", else: "FAIL"

      shell.info("#{String.pad_trailing(mark, 5)} #{String.pad_trailing(probe.id, 24)} #{ok}/#{runs}")

      for r <- runs_for, not r.pass do
        shell.info("        run #{r.run}: #{r.reason}")
        shell.info("        -> #{String.slice(r.answer, 0, 110)}")
      end
    end

    shell.info(String.duplicate("-", 78))
    shell.info("accuracy: #{passed}/#{total} (#{Float.round(passed / max(total, 1) * 100, 1)}%)")

    spend = spend_since(started_at)

    shell.info(
      "spend:    $#{:erlang.float_to_binary(spend.cost, decimals: 4)} " <>
        "over #{spend.calls} calls " <>
        "(#{Float.round(spend.cached_pct, 1)}% input cached)"
    )

    shell.info(
      "per ask:  $#{:erlang.float_to_binary(spend.cost / max(total, 1), decimals: 5)} " <>
        "| #{Float.round(spend.calls / max(total, 1), 2)} llm calls"
    )

    for {op, n, cost} <- spend.by_op do
      shell.info(
        "  #{String.pad_trailing(op, 26)} #{String.pad_leading(to_string(n), 4)} " <>
          "$#{:erlang.float_to_binary(cost, decimals: 4)}"
      )
    end

    # Escalates are reported separately because they are the trap in every
    # "cheaper model" experiment: a weaker classifier that false-positives on
    # bait BUYS a call to the expensive model, so the config that looks cheaper
    # per call can be the one that spends more. Counting them is the only way to
    # see it.
    shell.info(
      "escalates: #{spend.escalates} " <>
        "(#{Float.round(spend.escalates / max(total, 1) * 100, 1)}% of asks)"
    )

    if passed < total do
      shell.info("\nFAILURES PRESENT — do not ship this configuration.")
      exit({:shutdown, 1})
    end
  end

  # Cached input tokens bill at a fraction of the input rate, so list price would
  # overstate what the run actually cost — and overstating the incumbent's cost is
  # exactly how a bad optimization gets talked into looking good.
  defp spend_since(started_at) do
    rows =
      Repo.all(
        from l in "llm_logs",
          where: l.inserted_at >= ^started_at,
          select: %{
            op: l.operation,
            model: l.model,
            pt: l.prompt_tokens,
            ct: l.completion_tokens,
            detail: l.detail
          }
      )

    cost =
      Enum.reduce(rows, 0.0, fn r, acc ->
        cached = get_in(r.detail || %{}, ["cached_tokens"]) || 0
        gross = to_float(RuleMaven.LLM.Pricing.cost(r.model, r.pt || 0, r.ct || 0))
        saved = to_float(RuleMaven.LLM.Pricing.cached_savings(r.model, cached))
        acc + gross - saved
      end)

    prompt_total = Enum.sum(Enum.map(rows, &(&1.pt || 0)))
    cached_total = Enum.sum(Enum.map(rows, &(get_in(&1.detail || %{}, ["cached_tokens"]) || 0)))

    by_op =
      rows
      |> Enum.group_by(& &1.op)
      |> Enum.map(fn {op, rs} ->
        c =
          Enum.reduce(rs, 0.0, fn r, acc ->
            cached = get_in(r.detail || %{}, ["cached_tokens"]) || 0

            acc + to_float(RuleMaven.LLM.Pricing.cost(r.model, r.pt || 0, r.ct || 0)) -
              to_float(RuleMaven.LLM.Pricing.cached_savings(r.model, cached))
          end)

        {op, length(rs), c}
      end)
      |> Enum.sort_by(fn {_op, _n, c} -> -c end)

    escalate_model = LLM.model(:escalate)
    escalates = Enum.count(rows, &(&1.model == escalate_model and &1.op == "ask"))

    %{
      cost: cost,
      calls: length(rows),
      cached_pct: cached_total / max(prompt_total, 1) * 100,
      by_op: by_op,
      escalates: escalates
    }
  end

  defp to_float(n) when is_number(n), do: n * 1.0
end
