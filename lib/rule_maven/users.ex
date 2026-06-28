defmodule RuleMaven.Users do
  @moduledoc """
  User management — CRUD, authentication, role checks.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo
  alias RuleMaven.Users.{User, UserToken, UserNotifier}

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  def list_users do
    Repo.all(from u in User, order_by: [desc: u.inserted_at])
  end

  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a user with an auto-generated temp password.
  Returns {:ok, user, password} or {:error, changeset, password}.
  Admin uses this to manually create accounts for known users.
  """
  def create_user_with_temp_password(attrs) do
    password = generate_temp_password()

    case create_user(Map.put(attrs, :password, password)) do
      {:ok, user} -> {:ok, user, password}
      {:error, changeset} -> {:error, changeset, password}
    end
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def update_user_role(%User{} = user, role) do
    update_user(user, %{role: role})
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def delete_user(nil), do: {:error, :not_found}

  # --- email confirmation ----------------------------------------------------

  @doc "True once this user has confirmed their email address."
  def email_confirmed?(user), do: User.email_confirmed?(user)

  @doc """
  Generates a confirmation token, persists its hash, and mails the link.
  `url_fun` receives the raw token and returns the absolute confirm URL.
  No-op (returns `{:error, :already_confirmed}`) if already confirmed.
  """
  def deliver_user_confirmation_instructions(%User{} = user, url_fun)
      when is_function(url_fun, 1) do
    if User.email_confirmed?(user) do
      {:error, :already_confirmed}
    else
      {encoded, token} = UserToken.build_email_token(user)
      Repo.insert!(token)
      UserNotifier.deliver_confirmation_instructions(user, url_fun.(encoded))
    end
  end

  @doc """
  Confirms a user from an encoded token. Stamps `email_confirmed_at` and burns
  all of that user's confirmation tokens. Returns `{:ok, user}` or `:error`.
  """
  def confirm_user(encoded_token) do
    with {:ok, query} <- UserToken.verify_email_token_query(encoded_token),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts_query(user, ["confirm"])
    )
  end

  def authenticate(username, password) do
    user = get_user_by_username(username)

    case user do
      nil ->
        {:error, "Invalid username or password"}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, "Invalid username or password"}
        end
    end
  end

  @doc "Whether the user's role grants the given capability (see User.can?/2)."
  def can?(user, capability), do: User.can?(user, capability)

  def game_master?(user), do: User.game_master?(user)

  @doc "List of valid role strings."
  def roles, do: User.all_roles()

  @doc """
  Updates a user's profile (username, email). Validates uniqueness and required fields.
  """
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Changes a user's password. Requires current password verification.
  Returns {:ok, user} or {:error, reason}.
  """
  def change_password(%User{} = user, current_password, new_password) do
    unless Bcrypt.verify_pass(current_password, user.password_hash) do
      {:error, "Current password is incorrect."}
    else
      if String.length(new_password) < 4 do
        {:error, "New password must be at least 4 characters."}
      else
        password_hash = Bcrypt.hash_pwd_salt(new_password)

        user
        |> User.changeset(%{password_hash: password_hash})
        |> Repo.update()
      end
    end
  end

  defp generate_temp_password do
    :crypto.strong_rand_bytes(10) |> Base.encode32(padding: false)
  end
end
