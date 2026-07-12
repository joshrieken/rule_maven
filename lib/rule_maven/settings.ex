defmodule RuleMaven.Settings do
  @moduledoc """
  Simple key-value application settings persisted in the database.
  """

  alias RuleMaven.Repo
  alias RuleMaven.Settings.AppSetting
  alias RuleMaven.Settings.Cache

  @doc """
  Reads a setting value by key. Returns nil if not set.

  Served from `RuleMaven.Settings.Cache` when possible — hot paths read
  dozens of settings per request. Absent settings cache as nil too, so
  optional settings don't re-query on every read.
  """
  def get(key) do
    case Cache.get(key) do
      {:ok, value} ->
        value

      :miss ->
        value =
          case Repo.get(AppSetting, key) do
            %AppSetting{value: value} -> value
            nil -> nil
          end

        Cache.put(key, value)
        value
    end
  end

  @doc """
  Writes a setting value by key. Upserts via `ON CONFLICT` so concurrent
  writers can't race a get-then-insert/update round trip into a unique
  constraint violation — the last writer to reach Postgres wins.
  """
  def put(key, value) do
    result =
      %AppSetting{key: key}
      |> AppSetting.changeset(%{key: key, value: value})
      |> Repo.insert(
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: :key
      )

    with {:ok, _} <- result, do: Cache.invalidate(key)
    result
  end

  @doc "Deletes a setting by key. No-op if not set."
  def delete(key) do
    case Repo.get(AppSetting, key) do
      nil ->
        # The cache may hold a stale value for a row deleted out-of-band.
        Cache.invalidate(key)
        :ok

      existing ->
        result = Repo.delete(existing)
        with {:ok, _} <- result, do: Cache.invalidate(key)
        result
    end
  end

  @doc "Returns all settings as a map."
  def all do
    Repo.all(AppSetting)
    |> Map.new(fn %{key: key, value: value} -> {key, value} end)
  end

  # --- LLM kill switch -------------------------------------------------------

  @default_asks_disabled_message "Question answering is paused for maintenance. Please try again shortly — existing answers are still available."

  @doc "Banner/flash message shown while asks are disabled."
  def asks_disabled_message do
    case get("asks_disabled_message") do
      nil -> @default_asks_disabled_message
      "" -> @default_asks_disabled_message
      msg -> msg
    end
  end

  # --- Email -----------------------------------------------------------------

  @default_mail_from "no-reply@rulemaven.app"

  @doc """
  Sender address for outbound mail. Resend rejects senders from unverified
  domains, so prod must set this to an address on the verified domain.
  """
  def mail_from do
    case get("mail_from") do
      nil -> @default_mail_from
      "" -> @default_mail_from
      from -> from
    end
  end

  @doc "Sets the sender address for outbound mail."
  def set_mail_from(from) when is_binary(from), do: put("mail_from", String.trim(from))

  @doc """
  Whether dev sends real mail through Resend instead of the Local adapter
  (`/dev/mailbox`). Ignored outside dev.
  """
  def mail_dev_live?, do: get("mail_dev_live") == "true"

  @doc "Enables/disables real Resend sends from dev."
  def set_mail_dev_live(live?) when is_boolean(live?) do
    put("mail_dev_live", to_string(live?))
  end

  @doc """
  Resend API key for outbound mail. DB value (admin-editable) takes priority
  over the `RESEND_API_KEY` env var so ops can rotate the key without a deploy.
  """
  def resend_api_key do
    case get("resend_api_key") do
      nil -> System.get_env("RESEND_API_KEY")
      "" -> System.get_env("RESEND_API_KEY")
      key -> key
    end
  end

  @doc "Sets the Resend API key. Blank clears the DB override, falling back to env."
  def set_resend_api_key(key) when is_binary(key), do: put("resend_api_key", String.trim(key))

  @doc """
  Base URL used to build links in outbound email (password reset,
  confirmation, group invites sent by mail, etc). DB value (admin-editable)
  takes priority over the `:public_url` app config (PUBLIC_URL env var /
  PHX_HOST fallback in prod) so ops can repoint mail links without a deploy.
  No trailing slash.
  """
  def public_url do
    case get("public_url") do
      nil -> Application.fetch_env!(:rule_maven, :public_url)
      "" -> Application.fetch_env!(:rule_maven, :public_url)
      url -> url
    end
  end

  @doc "Sets the public URL. Blank clears the DB override, falling back to app config."
  def set_public_url(url) when is_binary(url) do
    put("public_url", url |> String.trim() |> String.trim_trailing("/"))
  end
end
