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

  @doc "Writes a setting value by key. Upserts to handle insert or update."
  def put(key, value) do
    case Repo.get(AppSetting, key) do
      nil -> %AppSetting{key: key}
      existing -> existing
    end
    |> AppSetting.changeset(%{key: key, value: value})
    |> Repo.insert_or_update()
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

  @doc """
  Whether new LLM-backed asks are disabled (kill switch / maintenance mode).
  Lets an operator stop spend or ride out a provider outage without a deploy.
  """
  def asks_disabled?, do: get("asks_disabled") == "true"

  @doc "Banner/flash message shown while asks are disabled."
  def asks_disabled_message do
    case get("asks_disabled_message") do
      nil -> @default_asks_disabled_message
      "" -> @default_asks_disabled_message
      msg -> msg
    end
  end

  @doc "Enables/disables new asks."
  def set_asks_disabled(disabled?) when is_boolean(disabled?) do
    put("asks_disabled", to_string(disabled?))
  end
end
