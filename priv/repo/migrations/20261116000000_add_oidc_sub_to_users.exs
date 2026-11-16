defmodule RuleMaven.Repo.Migrations.AddOidcSubToUsers do
  use Ecto.Migration

  # Single sign-on (shared Authentik): `oidc_sub` is the account's subject id at the provider,
  # the only thing sign-on matches people by (never email or username). Accounts created by
  # sign-on may have no email (the provider's address can already belong to an unlinked account
  # here), so email becomes optional; the unique index still applies to the ones that are set.
  def change do
    alter table(:users) do
      add :oidc_sub, :string
      modify :email, :string, null: true, from: {:string, null: false}
    end

    create unique_index(:users, [:oidc_sub])
  end
end
