defmodule RuleMaven.Hub do
  @moduledoc """
  What the Low-Cal Calzone Zone hub (`../hub`) shows on Rule Maven's place: a line of news and
  how built-up the place looks. The hub asks server to server for one person, by their sign-on
  id (`users.oidc_sub`), with the shared secret `RULEMAVEN_HUB_SECRET`
  (`GET /api/hub/summary?sub=…`, `RuleMavenWeb.HubController`). Read-only; no secret = refused.

  Contract (shared by every app the hub shows):
  `%{level: 0..3, active: boolean, headline: ≤80 chars, detail?: ≤120 chars, version, updated}`.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.{Changelog, Repo}
  alias RuleMaven.Games.{Game, QuestionLog}
  alias RuleMaven.Users.User

  @typedoc "One person's summary for the hub (`detail` only when there is one)."
  @type summary :: %{
          required(:level) => 0..3,
          required(:active) => boolean(),
          required(:headline) => String.t(),
          optional(:detail) => String.t(),
          required(:version) => String.t(),
          required(:updated) => boolean()
        }

  @day 86_400
  # Days back that count as "this week" (and light the place up).
  @active_days 7
  # Questions asked that reach levels 1, 2, 3: a first question, regular use, a rules regular.
  @levels [1, 10, 50]
  @headline_max 80
  @detail_max 120
  @sub_max 255

  def active_days, do: @active_days
  def levels, do: @levels
  def headline_max, do: @headline_max
  def detail_max, do: @detail_max
  def sub_max, do: @sub_max

  @doc """
  Is this the hub's `Authorization: Bearer <RULEMAVEN_HUB_SECRET>`? Compared in constant time
  (as SHA-256 digests, so lengths don't leak); always false while the secret is unset.
  """
  @spec hub_request?(String.t() | nil) :: boolean()
  def hub_request?(authorization) do
    secret = Application.get_env(:rule_maven, :hub_secret)

    with secret when is_binary(secret) and secret != "" <- secret,
         given when is_binary(given) <- bearer(authorization) do
      Plug.Crypto.secure_compare(digest(given), digest(secret))
    else
      _ -> false
    end
  end

  defp bearer(value) when is_binary(value) do
    case Regex.run(~r/\ABearer\s+(\S+)\z/i, String.trim(value)) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp bearer(_), do: nil

  defp digest(value), do: :crypto.hash(:sha256, value)

  @doc """
  The summary for the person with this sign-on id, or nil when nobody here has it (never signed
  in to Rule Maven) or their account is suspended.

  Counts the questions they asked (prepared answers an admin imported don't count; nor do
  failed asks).
  """
  @spec summary(String.t(), DateTime.t()) :: summary() | nil
  def summary(sub, now \\ DateTime.utc_now()) when is_binary(sub) do
    case Repo.get_by(User, oidc_sub: sub) do
      %User{suspended_at: nil} = user -> build(user, now)
      _ -> nil
    end
  end

  defp build(%User{} = user, now) do
    week_ago = DateTime.add(now, -@active_days * @day, :second)

    %{total: total, recent: recent, last: last} =
      Repo.one(
        from q in asked(user),
          select: %{
            total: count(q.id),
            recent: filter(count(q.id), q.inserted_at >= ^week_ago and q.inserted_at <= ^now),
            last: max(q.inserted_at)
          }
      )

    %{
      level: Enum.count(@levels, &(total >= &1)),
      active: recent > 0,
      headline: headline(recent, last, now),
      version: Changelog.app_version(),
      updated: Changelog.unseen_for?(user)
    }
    |> put_detail(last_game(user))
  end

  defp asked(%User{id: id}) do
    from q in QuestionLog,
      where: q.user_id == ^id and is_nil(q.error_kind),
      where: is_nil(q.llm_provider) or q.llm_provider != "manual"
  end

  defp headline(recent, _last, _now) when recent > 0,
    do: clip("#{plural(recent, "question")} this week", @headline_max)

  defp headline(_recent, nil, _now), do: "No questions yet. Pick a game and ask."

  defp headline(_recent, last, now) do
    days = max(1, div(DateTime.diff(now, last, :second), @day))
    clip("Last question #{plural(days, "day")} ago", @headline_max)
  end

  defp last_game(user) do
    Repo.one(
      from q in asked(user),
        join: g in Game,
        on: g.id == q.game_id,
        order_by: [desc: q.inserted_at, desc: q.id],
        limit: 1,
        select: g.name
    )
  end

  defp put_detail(summary, name) when is_binary(name) and name != "",
    do: Map.put(summary, :detail, clip("Last game: #{name}", @detail_max))

  defp put_detail(summary, _name), do: summary

  # One line, cut to `max` characters (game names come from BoardGameGeek and admins).
  defp clip(text, max) do
    line = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(line) > max,
      do: String.slice(line, 0, max - 1) |> String.trim_trailing() |> Kernel.<>("…"),
      else: line
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
