# BoardGameGeek via the official XML API2 with the app's bgg_api_key (BGG's web
# pages 403 automated fetches; the API is the sanctioned route). Run from repo root:
#   mix run --no-start .claude/skills/import-prepare/scripts/bgg_api.exs forums BGG_ID
#   mix run --no-start .claude/skills/import-prepare/scripts/bgg_api.exs thread THREAD_ID OUT.txt [user1,user2]
#   mix run --no-start .claude/skills/import-prepare/scripts/bgg_api.exs rulings BGG_ID user1,user2 OUT.txt [PAGES]
# `thread` keeps every post (or only posts by the listed usernames); `rulings` walks the
# game's "Rules" forum (PAGES x 50 threads, newest first, default 4) and keeps only posts
# by the listed designer/publisher usernames — each with its thread title and URL.
# Never prints the key. Sleeps 2s between calls (BGG rate limits).
Application.ensure_all_started(:req)
Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()

defmodule BggApi do
  @base "https://boardgamegeek.com/xmlapi2"
  def get(path) do
    Process.sleep(2000)
    tok = RuleMaven.Settings.get("bgg_api_key") || RuleMaven.Settings.get("bgg_api_token")
    hdrs = if tok, do: [{"authorization", "Bearer #{tok}"}], else: []
    case Req.get!(@base <> path, headers: hdrs, retry: :transient, receive_timeout: 60_000) do
      %{status: 200, body: b} -> b
      %{status: 202} -> get(path)
      %{status: s} -> raise "BGG #{path} -> HTTP #{s}"
    end
  end

  def text(html) do
    html
    |> HtmlEntities.decode_safe()
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/?(div|p|li|ul|ol|h\d)[^>]*>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> HtmlEntities.decode_safe()
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def posts(thread_id) do
    xml = get("/thread?id=#{thread_id}")
    subject = case Regex.run(~r/<subject>(.*?)<\/subject>/s, xml) do [_, s] -> text(s); _ -> "" end
    posts =
      Regex.scan(~r/<article id="(\d+)" username="([^"]*)"[^>]*?editdate="([^"]*)"[^>]*>.*?<body>(.*?)<\/body>/s, xml)
      |> Enum.map(fn [_, id, u, ed, body] -> %{id: id, user: u, edited: ed, text: text(body)} end)
    {subject, posts}
  end
end

defmodule HtmlEntities do
  # minimal decoder (XML-escaped HTML inside BGG bodies)
  def decode_safe(s) do
    s
    |> String.replace("&lt;", "<") |> String.replace("&gt;", ">") |> String.replace("&quot;", "\"")
    |> String.replace("&#039;", "'") |> String.replace("&#39;", "'") |> String.replace("&nbsp;", " ")
    |> then(&Regex.replace(~r/&#(\d+);/, &1, fn _, n -> <<String.to_integer(n)::utf8>> end))
    |> String.replace("&amp;", "&")
  end
end

case System.argv() do
  ["forums", bgg] ->
    xml = BggApi.get("/forumlist?id=#{bgg}&type=thing")
    for [_, id, title, n] <- Regex.scan(~r/<forum id="(\d+)"[^>]*title="([^"]*)"[^>]*numthreads="(\d+)"/, xml),
        do: IO.puts("forum #{id}  #{title}  (#{n} threads)")

  ["thread", tid, out | users] ->
    keep = users |> List.first("") |> String.split(",", trim: true)
    {subj, posts} = BggApi.posts(tid)
    posts = if keep == [], do: posts, else: Enum.filter(posts, &(&1.user in keep))
    body = Enum.map_join(posts, "\n\n", &"[#{&1.user}, post #{&1.id}, edited #{&1.edited}]\n#{&1.text}")
    File.write!(out, "Source: https://boardgamegeek.com/thread/#{tid} — #{subj} (BGG XML API, fetched #{Date.utc_today()})\n\n#{body}\n")
    IO.puts("THREAD #{tid} \"#{subj}\": #{length(posts)} posts → #{out}")

  ["rulings", bgg, users, out | rest] ->
    keep = String.split(users, ",", trim: true)
    pages = String.to_integer(List.first(rest, "4"))
    fl = BggApi.get("/forumlist?id=#{bgg}&type=thing")
    [rules_id | _] =
      for [_, id, title] <- Regex.scan(~r/<forum id="(\d+)"[^>]*title="([^"]*)"/, fl),
          String.downcase(title) =~ "rules", do: id

    threads =
      for p <- 1..pages, reduce: [] do
        acc ->
          xml = BggApi.get("/forum?id=#{rules_id}&page=#{p}")
          acc ++ (Regex.scan(~r/<thread id="(\d+)" subject="([^"]*)"/, xml) |> Enum.map(fn [_, id, s] -> {id, s} end))
      end

    found =
      for {tid, _} <- threads, reduce: [] do
        acc ->
          {subj, posts} = BggApi.posts(tid)
          mine = Enum.filter(posts, &(&1.user in keep))
          if mine == [], do: acc, else: acc ++ [{tid, subj, posts, mine}]
      end

    body =
      Enum.map_join(found, "\n\n----\n\n", fn {tid, subj, posts, mine} ->
        q = posts |> List.first() |> then(&"Q (#{&1.user}): #{String.slice(&1.text, 0, 1200)}")
        a = Enum.map_join(mine, "\n\n", &"RULING (#{&1.user}, #{&1.edited}): #{&1.text}")
        "Thread: #{subj}\nURL: https://boardgamegeek.com/thread/#{tid}\n#{q}\n\n#{a}"
      end)

    File.write!(out, "Designer/publisher rulings from the BGG Rules forum of thing #{bgg} by #{users} (BGG XML API, fetched #{Date.utc_today()}); #{length(threads)} threads scanned.\n\n#{body}\n")
    IO.puts("RULINGS: #{length(found)} threads with posts by #{users} (of #{length(threads)} scanned) → #{out}")

  ["posters", bgg | rest] ->
    # who answers in the Rules forum? designers/publisher staff stand out (then verify
    # the account via WebSearch / the game's BGG credits before trusting it)
    pages = String.to_integer(List.first(rest, "2"))
    fl = BggApi.get("/forumlist?id=#{bgg}&type=thing")
    [rules_id | _] = for [_, id, t] <- Regex.scan(~r/<forum id="(\d+)"[^>]*title="([^"]*)"/, fl), String.downcase(t) =~ "rules", do: id
    tids = for p <- 1..pages, [_, id] <- Regex.scan(~r/<thread id="(\d+)"/, BggApi.get("/forum?id=#{rules_id}&page=#{p}")), do: id
    counts =
      for tid <- tids, reduce: %{} do
        acc ->
          {_, posts} = BggApi.posts(tid)
          posts |> Enum.drop(1) |> Enum.map(& &1.user) |> Enum.uniq() |> Enum.reduce(acc, &Map.update(&2, &1, 1, fn n -> n + 1 end))
      end
    IO.puts("threads scanned: #{length(tids)} — users replying in the most threads:")
    for {u, n} <- counts |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(15), do: IO.puts("  #{n}  #{u}")

  _ ->
    IO.puts("usage: posters BGG_ID [PAGES] | forums BGG_ID | thread THREAD_ID OUT.txt [users] | rulings BGG_ID users OUT.txt [PAGES]")
end
