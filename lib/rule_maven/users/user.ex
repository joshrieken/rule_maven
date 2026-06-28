defmodule RuleMaven.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :role, :string, default: "player"
    field :password, :string, virtual: true
    field :password_hash, :string
    field :reputation, :integer, default: 0
    field :email_confirmed_at, :utc_datetime
    field :suspended_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @all_roles ["player", "admin"]

  # Capabilities granted to each role. To add a role: add it to @all_roles and
  # give it an entry here. To grant/revoke a power: edit its capability list.
  # All authorization flows through can?/2 so nothing is tied to a role name.
  @role_capabilities %{
    "player" => [],
    "admin" => [:admin]
  }

  def all_roles, do: @all_roles

  @doc "Whether the user's role grants the given capability."
  def can?(%{role: role}, capability),
    do: capability in Map.get(@role_capabilities, role, [])

  def can?(_, _), do: false

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :role, :password_hash])
    |> validate_required([:username, :email, :role])
    |> validate_inclusion(:role, @all_roles)
    |> validate_length(:username, max: 80)
    |> validate_length(:email, max: 160)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 4, max: 128)
    |> put_password_hash()
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email])
    |> validate_required([:username, :email])
    |> validate_length(:username, max: 80)
    |> validate_length(:email, max: 160)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  @doc "Validates and hashes a new password (used by password reset)."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 4, max: 128)
    |> put_password_hash()
  end

  @doc "Stamps the account as email-confirmed (no-op shape if already set)."
  def confirm_changeset(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(user, email_confirmed_at: now)
  end

  @doc "True once the account's email address has been confirmed."
  def email_confirmed?(%__MODULE__{email_confirmed_at: nil}), do: false
  def email_confirmed?(%__MODULE__{email_confirmed_at: _}), do: true
  def email_confirmed?(_), do: false

  @doc "True while the account is suspended (login + sessions denied)."
  def suspended?(%__MODULE__{suspended_at: nil}), do: false
  def suspended?(%__MODULE__{suspended_at: _}), do: true
  def suspended?(_), do: false

  @doc "Toggles suspension. `true` stamps now, `false` clears it."
  def suspension_changeset(user, true) do
    change(user, suspended_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def suspension_changeset(user, false), do: change(user, suspended_at: nil)

  @doc "True for anyone with the :admin capability."
  def admin?(user), do: can?(user, :admin)

  defp put_password_hash(changeset) do
    case changeset do
      %{valid?: true, changes: %{password: pass}} ->
        put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(pass))

      _ ->
        changeset
    end
  end
end
