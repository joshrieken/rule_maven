defmodule RuleMaven.Settings do
  @moduledoc """
  Simple key-value application settings persisted in the database.
  """

  alias RuleMaven.Repo
  alias RuleMaven.Settings.AppSetting

  @doc "Reads a setting value by key. Returns nil if not set."
  def get(key) do
    case Repo.get(AppSetting, key) do
      %AppSetting{value: value} -> value
      nil -> nil
    end
  end

  @doc """
  Writes a setting value by key. Upserts via `ON CONFLICT` so concurrent
  writers can't race a get-then-insert/update round trip into a unique
  constraint violation — the last writer to reach Postgres wins.
  """
  def put(key, value) do
    %AppSetting{key: key}
    |> AppSetting.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  @doc "Deletes a setting by key. No-op if not set."
  def delete(key) do
    case Repo.get(AppSetting, key) do
      nil -> :ok
      existing -> Repo.delete(existing)
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
end
