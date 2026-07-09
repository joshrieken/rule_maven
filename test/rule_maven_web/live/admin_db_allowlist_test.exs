defmodule RuleMavenWeb.AdminDbAllowlistTest do
  @moduledoc """
  The raw DB editor writes through an allowlist. These assertions are the
  contract: identity and audit tables must never appear in it, and any table
  that exists but isn't listed is read-only by default (fail closed).
  """
  use RuleMaven.DataCase, async: true

  alias RuleMavenWeb.AdminLive.Db

  @never_writable ~w(users user_tokens audit_logs schema_migrations)

  test "identity and audit tables are not in the allowlist" do
    for table <- @never_writable do
      refute table in Db.__writable_tables__(),
             "#{table} must never be writable through the raw DB editor"
    end
  end

  test "the allowlist names no oban table" do
    refute Enum.any?(Db.__writable_tables__(), &String.starts_with?(&1, "oban"))
  end

  test "every allowlisted table actually exists" do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        RuleMaven.Repo,
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public'",
        []
      )

    existing = MapSet.new(List.flatten(rows))

    for table <- Db.__writable_tables__() do
      assert MapSet.member?(existing, table), "allowlist names a missing table: #{table}"
    end
  end
end
