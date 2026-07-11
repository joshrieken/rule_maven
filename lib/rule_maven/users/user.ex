defmodule RuleMaven.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :role, :string, default: "user"
    field :password, :string, virtual: true
    field :password_hash, :string
    field :reputation, :integer, default: 0
    field :curator_points, :integer, default: 0
    field :curator_seen_at, :utc_datetime
    field :email_confirmed_at, :utc_datetime
    field :suspended_at, :utc_datetime
    # Force-logout cutoff: sessions whose login predates this are rejected. An
    # admin "force logout" stamps this to now, invalidating all live sessions.
    field :sessions_valid_after, :utc_datetime
    # Per-user monthly question allowance (fresh LLM generations only; cache hits
    # don't count). Replaces the global monthly limit; an admin can raise it.
    field :monthly_quota, :integer, default: 200
    # Onboarding tours completed/skipped: tour id => ISO8601 timestamp. A tour
    # auto-starts on its page until its key appears here.
    field :tours_seen, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @all_roles ["user", "admin", "super_admin"]

  # Roles the application may assign through any web path. "super_admin" is
  # deliberately absent: it is grantable only by `mix rule_maven.grant_superadmin`
  # run on the server, so a forged LiveView param or a compromised admin account
  # can never mint one.
  @assignable_roles ["user", "admin"]

  # Capabilities granted to each role. To add a role: add it to @all_roles and
  # give it an entry here. To grant/revoke a power: edit its capability list.
  # All authorization flows through can?/2 so nothing is tied to a role name.
  @role_capabilities %{
    "user" => [],
    "admin" => [:admin],
    "super_admin" => [:admin, :superadmin]
  }

  # Single source of truth for password strength — every entry point (registration,
  # reset, change-password, and the LiveView pre-check) validates against this.
  @min_password_length 10
  @max_password_length 128

  def all_roles, do: @all_roles

  @doc "Human-readable password rule, shown in forms and error messages."
  def password_requirements,
    do: "At least #{@min_password_length} characters, including a letter and a number."

  @doc "Server-side pre-check mirroring the changeset rule, for LiveView inline validation."
  def valid_password?(password) when is_binary(password) do
    String.length(password) >= @min_password_length and
      String.length(password) <= @max_password_length and
      String.match?(password, ~r/[a-zA-Z]/) and
      String.match?(password, ~r/[0-9]/)
  end

  def valid_password?(_), do: false

  @doc "Roles the admin UI may assign. Excludes super_admin (mix task only)."
  def assignable_roles, do: @assignable_roles

  @doc "True for the owner account: every capability, immune to admin moderation."
  def super_admin?(user), do: can?(user, :superadmin)

  @doc "Whether the user's role grants the given capability."
  def can?(%{role: role}, capability),
    do: capability in Map.get(@role_capabilities, role, [])

  def can?(_, _), do: false

  @doc "Role strings whose capability list includes `capability` — for SQL-side filtering."
  def roles_with_capability(capability) do
    for {role, caps} <- @role_capabilities, capability in caps, do: role
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :role, :password_hash])
    |> validate_required([:username, :email, :role])
    |> validate_inclusion(:role, @assignable_roles)
    |> protect_super_admin_role()
    |> validate_length(:username, max: 80)
    |> validate_length(:email, max: 160)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  # A super admin's role cannot be changed through the ordinary changeset —
  # only `elevation_changeset/2` (mix task) may move a user in or out of it.
  defp protect_super_admin_role(changeset) do
    if super_admin?(changeset.data) and get_change(changeset, :role) do
      add_error(changeset, :role, "a super admin's role can only be changed on the server")
    else
      changeset
    end
  end

  @doc """
  Sets a role with no assignable-role restriction. The ONLY changeset that can
  grant or revoke "super_admin". Reserved for the server-side mix tasks; never
  reachable from a controller, LiveView, or the raw DB editor.
  """
  def elevation_changeset(user, role) do
    user
    |> cast(%{role: role}, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @all_roles)
  end

  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password_strength()
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
    |> validate_password_strength()
    |> put_password_hash()
  end

  defp validate_password_strength(changeset) do
    changeset
    |> validate_length(:password, min: @min_password_length, max: @max_password_length)
    |> validate_format(:password, ~r/[a-zA-Z]/, message: "must contain at least one letter")
    |> validate_format(:password, ~r/[0-9]/, message: "must contain at least one number")
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

  @doc "Stamps the force-logout cutoff to now, revoking all existing sessions."
  def force_logout_changeset(user) do
    change(user, sessions_valid_after: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  True if a session that logged in at `logged_in_at` (unix seconds, or nil for
  legacy sessions) is still valid for this user. A revocation cutoff with no
  recorded login time fails closed.
  """
  def session_valid?(%__MODULE__{sessions_valid_after: nil}, _logged_in_at), do: true
  def session_valid?(%__MODULE__{}, nil), do: false

  def session_valid?(%__MODULE__{sessions_valid_after: cutoff}, logged_in_at)
      when is_integer(logged_in_at) do
    logged_in_at >= DateTime.to_unix(cutoff)
  end

  def session_valid?(_, _), do: false

  @doc "Admin-set monthly question quota. Clamped to a sane non-negative range."
  def quota_changeset(user, quota) do
    user
    |> cast(%{monthly_quota: quota}, [:monthly_quota])
    |> validate_required([:monthly_quota])
    |> validate_number(:monthly_quota,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
  end

  @doc "Stamps an onboarding tour as seen (completed or skipped)."
  def tour_seen_changeset(user, tour_id) when is_binary(tour_id) do
    seen = Map.put(user.tours_seen || %{}, tour_id, DateTime.utc_now() |> DateTime.to_iso8601())
    change(user, tours_seen: seen)
  end

  @doc "True once the user has completed or skipped the given tour."
  def tour_seen?(%__MODULE__{tours_seen: seen}, tour_id) when is_map(seen),
    do: Map.has_key?(seen, tour_id)

  def tour_seen?(_, _), do: false

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
