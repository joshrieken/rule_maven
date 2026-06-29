defmodule RuleMaven.BGG do
  @moduledoc """
  BoardGameGeek XML API v2 client. Supports optional cookie-based
  authentication for private collections.
  """

  import SweetXml

  @base "https://boardgamegeek.com/xmlapi2"
  @login_url "https://boardgamegeek.com/login/api/v1"
  @data_dump_url "https://boardgamegeek.com/data_dumps/bg_ranks"

  @doc """
  Authenticates with BGG and returns session cookies for subsequent requests.
  Returns `{:ok, cookies}` or `{:error, reason}`.
  """
  def login(username, password) do
    body = %{credentials: %{username: username, password: password}}

    case Req.post(@login_url, json: body) do
      # BGG returns 204 No Content on success (200 historically); cookies are in
      # the Set-Cookie response headers either way.
      {:ok, %{status: status, headers: headers}} when status in [200, 204] ->
        {:ok, extract_cookies(headers)}

      {:ok, %{status: 401}} ->
        {:error, "Invalid BGG username or password"}

      {:ok, %{status: status}} ->
        {:error, "BGG login returned status #{status}"}

      {:error, reason} ->
        {:error, "Login HTTP error: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches a user's game collection from BGG.
  Accepts optional `cookies` keyword for authenticated access to private collections.
  Returns `{:ok, [%{name: name, bgg_id: bgg_id}]}` or `{:error, reason}`.
  """
  def fetch_collection(username, opts \\ []) do
    cookies = Keyword.get(opts, :cookies)
    url = "#{@base}/collection?username=#{URI.encode_www_form(username)}&own=1&stats=1"
    headers = build_headers(cookies)

    case Req.get(url, headers: headers, max_retries: 0, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        parse_collection(body)

      {:ok, %{status: 202, body: _body}} ->
        poll_accepted(username, cookies)

      {:ok, %{status: 401}} ->
        {:error, "BGG collection is private. Provide BGG credentials for access."}

      {:ok, %{status: 404}} ->
        {:error, "BGG username '#{username}' not found"}

      {:ok, %{status: status}} ->
        {:error, "BGG API returned status #{status}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  defp poll_accepted(username, cookies, attempt \\ 0) do
    if attempt > 10 do
      {:error, "BGG collection still queued after 10 polls"}
    else
      :timer.sleep(2000 * attempt + 2000)

      url = "#{@base}/collection?username=#{URI.encode_www_form(username)}&own=1&stats=1"

      case Req.get(url, headers: build_headers(cookies)) do
        {:ok, %{status: 200, body: body}} ->
          parse_collection(body)

        {:ok, %{status: 202}} ->
          poll_accepted(username, cookies, attempt + 1)

        {:ok, %{status: 401}} ->
          {:error, "BGG collection is private. Provide BGG credentials for access."}

        {:ok, %{status: status}} ->
          {:error, "BGG API returned status #{status}"}

        {:error, reason} ->
          {:error, "HTTP error: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Downloads BGG's official ranked-games data dump (the full catalog) and
  returns the decompressed CSV as a binary.

  The data_dumps page is login-gated; authentication comes from the configured
  BGG API token attached by `build_headers/1`. Optional `cookies` (from
  `login/2`) may still be passed for token-less setups. Flow: load the dump
  page, scrape the time-limited signed S3 URL, download the ZIP, unzip in
  memory, return the CSV entry.

  Returns `{:ok, csv_binary}` or `{:error, reason}`.
  """
  def fetch_rank_dump(cookies \\ nil) do
    require Logger

    with {:ok, page} <- get_dump_page(cookies),
         {:ok, zip_url} <- extract_dump_url(page),
         {:ok, zip} <- download_zip(zip_url),
         {:ok, csv} <- unzip_csv(zip) do
      Logger.info("BGG rank dump: #{byte_size(csv)} bytes of CSV")
      {:ok, csv}
    end
  end

  defp get_dump_page(cookies) do
    case Req.get(@data_dump_url,
           headers: build_headers(cookies),
           redirect: true,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, "BGG data dump page returned a non-text body"}

      {:ok, %{status: status}} ->
        {:error, "BGG data dump page returned status #{status} (are credentials valid?)"}

      {:error, reason} ->
        {:error, "Data dump page HTTP error: #{inspect(reason)}"}
    end
  end

  # The page embeds a time-limited signed link to the dated ZIP on S3.
  defp extract_dump_url(page) do
    regex = ~r{https://[^\s"'<>]+?(?:amazonaws\.com|geekdo-files\.com)[^\s"'<>]+?\.zip[^\s"'<>]*}

    case Regex.run(regex, page) do
      [url | _] ->
        {:ok, url |> String.replace("&amp;", "&")}

      nil ->
        require Logger
        Logger.error("BGG dump: no download URL found in page (#{byte_size(page)} bytes)")
        {:error, "Could not find the data dump download link. You may need to log in to BGG."}
    end
  end

  defp download_zip(url) do
    case Req.get(url, redirect: true, receive_timeout: 120_000, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "Data dump download returned status #{status}"}

      {:error, reason} ->
        {:error, "Data dump download HTTP error: #{inspect(reason)}"}
    end
  end

  defp unzip_csv(zip) do
    case :zip.unzip(zip, [:memory]) do
      {:ok, entries} ->
        csv =
          Enum.find_value(entries, fn {name, content} ->
            if String.ends_with?(to_string(name), ".csv"), do: content
          end)

        if csv, do: {:ok, csv}, else: {:error, "No CSV found inside the data dump ZIP"}

      {:error, reason} ->
        {:error, "Failed to unzip data dump: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches detailed info for a game by BGG id.
  Returns `{:ok, info_map}` or `{:error, reason}`.
  """
  def fetch_game_info(bgg_id) do
    url = "#{@base}/thing?id=#{bgg_id}"
    headers = build_headers(nil)

    require Logger
    Logger.debug("Fetching game info: #{url}")

    case Req.get(url, headers: headers, max_retries: 0, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Game info fetched for #{bgg_id}: #{byte_size(body)} bytes")
        {:ok, info} = parse_game_info(body)
        {:ok, info, body}

      {:ok, %{status: 202}} ->
        :timer.sleep(3000)
        fetch_game_info(bgg_id)

      {:ok, %{status: 429}} ->
        Logger.warning("BGG rate limited, waiting 10s...")
        :timer.sleep(10_000)
        fetch_game_info(bgg_id)

      {:ok, %{status: status}} ->
        Logger.error("BGG game info returned status #{status}")
        {:error, "BGG API returned status #{status}"}

      {:error, reason} ->
        Logger.error("BGG game info HTTP error: #{inspect(reason)}")
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches game info and updates the game record in the DB.
  Returns `{:ok, game}` or `{:error, reason}`.
  """
  def enrich_game(game, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    if game.bgg_data && !force? do
      # Use cached data, don't hit BGG API
      relink_from_cache(game)

      game
      # no-op update to return {:ok, game}
      |> RuleMaven.Games.update_game(%{})
    else
      fetch_and_enrich(game)
    end
  end

  defp fetch_and_enrich(game) do
    case fetch_game_info(game.bgg_id) do
      {:ok, info, raw_xml} ->
        expansion_links = Map.get(info, :expansion_links, [])
        info = Map.delete(info, :expansion_links)
        info = Map.put(info, :bgg_data, raw_xml)

        case RuleMaven.Games.update_game(game, info) do
          {:ok, updated} ->
            if expansion_links != [] do
              link_expansions(updated, expansion_links)
            end

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Re-parses expansion links from a game's cached BGG XML data.
  Useful to re-link expansions without hitting BGG API again.
  Returns :ok or {:error, reason}.
  """
  def relink_from_cache(%RuleMaven.Games.Game{} = game) do
    if game.bgg_data do
      {:ok, info} = parse_game_info(game.bgg_data)
      expansion_links = Map.get(info, :expansion_links, [])

      if expansion_links != [] do
        link_expansions(game, expansion_links)
      end

      :ok
    else
      {:error, "No cached BGG data for this game"}
    end
  end

  defp parse_game_info(xml) do
    parsed =
      xml
      |> parse()
      |> xpath(
        ~x"//items/item"e,
        year_published: ~x"./yearpublished/@value"s |> transform_by(&parse_int/1),
        min_players: ~x"./minplayers/@value"s |> transform_by(&parse_int/1),
        max_players: ~x"./maxplayers/@value"s |> transform_by(&parse_int/1),
        playing_time: ~x"./playingtime/@value"s |> transform_by(&parse_int/1),
        image_url: ~x"./image/text()"s,
        thumbnail_url: ~x"./thumbnail/text()"s,
        links: [
          ~x"./link[@type='boardgameexpansion']"l,
          id: ~x"./@id"s |> transform_by(&parse_int/1),
          value: ~x"./@value"s,
          inbound: ~x"./@inbound"s
        ]
      )

    {:ok,
     %{
       year_published: parsed.year_published,
       min_players: parsed.min_players,
       max_players: parsed.max_players,
       playing_time: parsed.playing_time,
       image_url: parsed.image_url,
       expansion_links: parsed.links
     }}
  end

  defp parse_int(""), do: nil
  defp parse_int(nil), do: nil
  defp parse_int(str), do: String.to_integer(str)

  @doc """
  After enriching a game, auto-link its expansions.
  Looks for games in the DB with matching BGG IDs from the link data.
  """
  def link_expansions(game, expansion_links) do
    # inbound="true" means THIS game is an expansion of the linked game
    # Set this game's parent to the linked game
    inbound = Enum.filter(expansion_links, &(&1.inbound == "true"))

    # An expansion can list several inbound parents on BGG (e.g. also linked to a
    # bundle or a standalone). Only adopt a parent when this game has none yet —
    # never overwrite an existing parent, or re-enriching one expansion would
    # yank it out from under the base whose outbound link already claimed it.
    if inbound != [] and is_nil(game.parent_game_id) do
      parent =
        inbound
        |> Enum.map(&RuleMaven.Repo.get_by(RuleMaven.Games.Game, bgg_id: &1.id))
        |> Enum.find(& &1)

      if parent do
        RuleMaven.Games.update_game(game, %{parent_game_id: parent.id})
      end
    end

    # inbound="false" means the linked game is an expansion OF this game
    # Find those games in DB and set their parent to this game
    outbound = Enum.filter(expansion_links, &(&1.inbound != "true"))

    Enum.each(outbound, fn link ->
      expansion = RuleMaven.Repo.get_by(RuleMaven.Games.Game, bgg_id: link.id)

      if expansion && is_nil(expansion.parent_game_id) do
        RuleMaven.Games.update_game(expansion, %{parent_game_id: game.id})
      end
    end)

    :ok
  end

  @doc """
  Number of expansions BGG lists *for* this game (outbound expansion links in
  its cached `bgg_data`). Returns 0 when there is no cached data or no links —
  used to decide whether to offer an expansion pull after enrichment.
  """
  def expansion_link_count(%RuleMaven.Games.Game{bgg_data: nil}), do: 0

  def expansion_link_count(%RuleMaven.Games.Game{bgg_data: xml}) do
    {:ok, info} = parse_game_info(xml)

    info
    |> Map.get(:expansion_links, [])
    |> Enum.count(&(&1.inbound != "true"))
  end

  def expansion_link_count(_), do: 0

  @doc """
  Searches BGG for board games by name. Returns `{:ok, [%{bgg_id: id, name: name, year: year}]}`.
  """
  def search(query) do
    url = "#{@base}/search?query=#{URI.encode_www_form(query)}&type=boardgame"
    headers = build_headers(nil)

    case Req.get(url, headers: headers, max_retries: 0, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} -> parse_search(body)
      {:ok, %{status: 429}} -> {:error, "Rate limited. Wait a moment."}
      {:ok, %{status: status}} -> {:error, "BGG returned status #{status}"}
      {:error, reason} -> {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  defp parse_search(xml) do
    parsed =
      xml
      |> parse()
      |> xpath(
        ~x"//items/item"l,
        bgg_id: ~x"./@id"s,
        name: ~x"./name/@value"s,
        year: ~x"./yearpublished/@value"s
      )

    games =
      parsed
      |> Enum.filter(& &1.bgg_id)
      |> Enum.map(fn item ->
        bgg_id =
          case Integer.parse(item.bgg_id) do
            {id, _} -> id
            _ -> nil
          end

        %{
          bgg_id: bgg_id,
          name: item.name || "",
          year: item.year
        }
      end)
      |> Enum.filter(& &1.bgg_id)

    {:ok, games}
  end

  defp build_headers(cookies) do
    headers = []

    headers =
      if cookies do
        [{"cookie", cookies} | headers]
      else
        headers
      end

    headers =
      case api_token() do
        nil -> headers
        token -> [{"authorization", "Bearer #{token}"} | headers]
      end

    headers
  end

  defp api_token do
    RuleMaven.Settings.get("bgg_api_key") ||
      RuleMaven.Settings.get("bgg_api_token")
  end

  defp extract_cookies(headers) do
    headers
    |> set_cookie_values()
    |> Enum.map(fn v -> v |> String.split(";") |> List.first() end)
    |> Enum.join("; ")
  end

  # Req returns response headers either as a list of {name, value} tuples or as
  # a map of name => [values] depending on version; handle both.
  defp set_cookie_values(headers) when is_map(headers), do: Map.get(headers, "set-cookie", [])

  defp set_cookie_values(headers) when is_list(headers) do
    for {k, v} <- headers, String.downcase(k) == "set-cookie", do: v
  end

  defp parse_collection(xml) do
    games =
      xml
      |> parse()
      |> xpath(
        ~x"//items/item"l,
        objectid: ~x"./@objectid"s,
        name: ~x"./name/text()"s,
        # stats=1 carries lightweight metadata for the whole collection in one
        # request (no per-game calls), used to seed freshly-created catalog rows.
        year_published: ~x"./yearpublished/text()"s |> transform_by(&parse_int/1),
        image_url: ~x"./image/text()"s,
        thumbnail_url: ~x"./thumbnail/text()"s,
        min_players: ~x"./stats/@minplayers"s |> transform_by(&parse_int/1),
        max_players: ~x"./stats/@maxplayers"s |> transform_by(&parse_int/1),
        playing_time: ~x"./stats/@playingtime"s |> transform_by(&parse_int/1)
      )
      |> Enum.map(&build_game/1)
      |> Enum.reject(&is_nil/1)

    {:ok, games}
  end

  defp build_game(item) do
    case Integer.parse(item.objectid) do
      {id, ""} ->
        name = String.trim(item.name)

        if name != "" do
          %{
            bgg_id: id,
            name: name,
            year_published: item.year_published,
            image_url: blank_to_nil(item.image_url),
            thumbnail_url: blank_to_nil(item.thumbnail_url),
            min_players: item.min_players,
            max_players: item.max_players,
            playing_time: item.playing_time
          }
        end

      _ ->
        nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
