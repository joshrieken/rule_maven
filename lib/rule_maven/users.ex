defmodule RuleMaven.Users do
  @moduledoc """
  User management — CRUD, authentication, role checks.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo
  alias RuleMaven.Users.{AuthCache, User, UserToken, UserNotifier}

  @doc "Human-readable password rule, for forms and error messages (see User.password_requirements/0)."
  def password_requirements, do: User.password_requirements()

  @doc "Pre-check mirroring the changeset password rule, for LiveView inline validation."
  def valid_password?(password), do: User.valid_password?(password)

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  def get_user_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^normalized)
  end

  def get_user_by_email(_), do: nil

  def list_users do
    Repo.all(from u in User, order_by: [desc: u.inserted_at])
  end

  @doc "Username typeahead for admin tooling (e.g. filtering the Questions list by asker)."
  def search_users(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 15)
    term = "%#{String.trim(query || "")}%"

    Repo.all(
      from u in User,
        where: ilike(u.username, ^term),
        order_by: [asc: u.username],
        limit: ^limit
    )
  end

  @doc "Count of users holding :admin (any role that grants it). Last-admin lockout guard."
  def count_admins do
    admin_roles = User.roles_with_capability(:admin)
    Repo.aggregate(from(u in User, where: u.role in ^admin_roles), :count)
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
    |> bust_auth_cache()
  end

  # The per-event LiveView reauth check (RuleMavenWeb.UserLiveAuth) reads the
  # user through RuleMaven.Users.AuthCache instead of the DB. Every write that
  # can change login standing (suspension, session validity, role) must drop
  # that cache entry — synchronously plus a PubSub broadcast for other nodes —
  # so revocation is visible to the very next event, not after the TTL.
  defp bust_auth_cache({:ok, %User{} = user} = result) do
    AuthCache.invalidate(user.id)
    result
  end

  defp bust_auth_cache(result), do: result

  def update_user_role(%User{} = user, role) do
    unless_super_admin(user, &update_user(&1, %{role: role}))
  end

  @doc """
  True for the owner account. Super admins hold every capability and are immune
  to admin moderation: the guards below are context-level, not UI-level, because
  LiveView events are forgeable over the socket.

  The role is grantable only by `mix rule_maven.grant_superadmin` on the server.
  """
  def super_admin?(user), do: User.super_admin?(user)

  # Every destructive action an admin can take against another account routes
  # through here. Returns {:error, :super_admin} rather than raising so callers
  # can surface a flash.
  defp unless_super_admin(%User{} = user, fun) do
    if User.super_admin?(user), do: {:error, :super_admin}, else: fun.(user)
  end

  @doc """
  Grants or revokes "super_admin". Server-side only — called by the mix tasks.
  Nothing in the web layer may call this.
  """
  def set_super_admin(%User{} = user, true?) do
    role = if true?, do: "super_admin", else: "user"

    user
    |> User.elevation_changeset(role)
    |> Repo.update()
    |> bust_auth_cache()
  end

  @doc """
  Demotes an admin to a regular user, refusing to remove the last remaining
  admin. The count + update run in one transaction with the admin rows locked
  `FOR UPDATE`, so two concurrent demotions can't both pass the check and strand
  the app with zero admins. Returns {:ok, user} | {:error, :last_admin} |
  {:error, :not_admin}.
  """
  def demote_admin(%User{} = user),
    do: user |> unless_super_admin(&do_demote_admin/1) |> bust_auth_cache()

  defp do_demote_admin(%User{} = user) do
    Repo.transaction(fn ->
      # Lock all admin rows for the duration so a concurrent demotion serializes
      # behind this one and re-reads the post-update count. (Postgres rejects
      # FOR UPDATE alongside an aggregate, so select the rows and count them.)
      admin_roles = User.roles_with_capability(:admin)

      admin_ids =
        Repo.all(from u in User, where: u.role in ^admin_roles, select: u.id, lock: "FOR UPDATE")

      cond do
        not User.can?(user, :admin) -> Repo.rollback(:not_admin)
        length(admin_ids) <= 1 -> Repo.rollback(:last_admin)
        true -> Repo.update!(User.changeset(user, %{role: "user"}))
      end
    end)
  end

  def delete_user(%User{} = user) do
    # `question_votes.user_id` is ON DELETE CASCADE, and `trust_score` is only
    # ever recomputed inside the vote/verify paths — so deleting a user silently
    # removes their vote weight while every row they voted on keeps the score
    # those votes bought. Banning a sybil ring left its target answers sitting
    # above `trusted_floor` (and above the raised report-pull quorum that the
    # trusted tier grants) indefinitely. Capture the affected rows first, then
    # recompute after the cascade.
    voted_on =
      Repo.all(
        from v in RuleMaven.Games.QuestionVote,
          where: v.user_id == ^user.id,
          select: v.question_log_id
      )

    with {:ok, deleted} <- unless_super_admin(user, &do_delete_user/1) do
      AuthCache.invalidate(deleted.id)
      rows = Repo.all(from q in RuleMaven.Games.QuestionLog, where: q.id in ^voted_on)
      Enum.each(rows, &RuleMaven.Games.Trust.recompute_trust/1)

      rows
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(&RuleMaven.Games.Trust.recompute_reputation/1)

      {:ok, deleted}
    end
  end

  def delete_user(nil), do: {:error, :not_found}

  # Any group the user owns must be handed off (or deleted, if they were
  # its only member) BEFORE the user row disappears — `groups.owner_id`
  # only nilifies on delete, so without this fixup the group would survive
  # with zero "owner" rows, an unrecoverable state (see
  # `RuleMaven.Groups.handle_owner_account_deletion/1`). Wrapping both in
  # one transaction means there is never a window where the user is gone
  # but a group hasn't been fixed up yet.
  defp do_delete_user(%User{} = user) do
    Repo.transaction(fn ->
      RuleMaven.Groups.handle_owner_account_deletion(user)

      case Repo.delete(user) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # --- moderation ------------------------------------------------------------

  @doc "True while the account is suspended (login + sessions denied)."
  def suspended?(user), do: User.suspended?(user)

  @doc "Suspends the account: blocks login and denies existing sessions."
  def suspend_user(%User{} = user) do
    user
    |> unless_super_admin(&(&1 |> User.suspension_changeset(true) |> Repo.update()))
    |> bust_auth_cache()
  end

  @doc "Lifts suspension."
  def unsuspend_user(%User{} = user),
    do: user |> User.suspension_changeset(false) |> Repo.update() |> bust_auth_cache()

  @doc "Revokes all of a user's live sessions (force logout) without suspending."
  def force_logout(%User{} = user) do
    user
    |> unless_super_admin(&(&1 |> User.force_logout_changeset() |> Repo.update()))
    |> bust_auth_cache()
  end

  @doc "Whether a session (login time in unix seconds) is still valid for the user."
  def session_valid?(user, logged_in_at), do: User.session_valid?(user, logged_in_at)

  @doc "Sets a user's monthly question quota (admin action)."
  def set_quota(%User{} = user, quota),
    do: unless_super_admin(user, &(&1 |> User.quota_changeset(quota) |> Repo.update()))

  @doc "Zeroes a user's reputation. Trust recompute on their rows can re-derive it."
  def reset_reputation(%User{} = user),
    do: unless_super_admin(user, &(&1 |> Ecto.Changeset.change(reputation: 0) |> Repo.update()))

  @doc "Marks an onboarding tour as seen (completed or skipped)."
  def mark_tour_seen(%User{} = user, tour_id),
    do: user |> User.tour_seen_changeset(tour_id) |> Repo.update()

  @doc "True once the user has completed or skipped the given tour."
  def tour_seen?(user, tour_id), do: User.tour_seen?(user, tour_id)

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

  # --- password reset --------------------------------------------------------

  @doc """
  Sends a password-reset link to the account with this email, if one exists.
  `url_fun` receives the raw token and returns the absolute reset URL. Returns
  `:ok` when no account matches; the caller (controller) renders the same
  response either way, so this never reveals over HTTP whether the email exists.
  """
  def deliver_password_reset_instructions(email, url_fun) when is_function(url_fun, 1) do
    case get_user_by_email(email) do
      %User{} = user ->
        {encoded, token} = UserToken.build_email_token(user, "reset")
        Repo.insert!(token)
        UserNotifier.deliver_reset_password_instructions(user, url_fun.(encoded))

      _ ->
        :ok
    end
  end

  @doc """
  Resets a password from an encoded reset token. Updates the hash and burns all
  of the user's reset tokens in one transaction. Returns `{:ok, user}`,
  `{:error, changeset}` on a weak password, or `:error` for a bad/expired token.
  """
  def reset_password(encoded_token, new_password) do
    with {:ok, query} <- UserToken.verify_email_token_query(encoded_token, "reset"),
         %User{} = user <- Repo.one(query) do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.update(:user, User.password_changeset(user, %{password: new_password}))
        |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["reset"]))

      case Repo.transaction(multi) do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, :user, changeset, _} -> {:error, changeset}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  # --- magic-link sign-in -----------------------------------------------------

  @doc """
  Sends a passwordless sign-in link to the account with this email, if one
  exists. `url_fun` receives the raw token and returns the absolute sign-in
  URL. Returns `:ok` when no account matches — same no-enumeration contract as
  `deliver_password_reset_instructions/2`.
  """
  def deliver_magic_link_instructions(email, url_fun) when is_function(url_fun, 1) do
    case get_user_by_email(email) do
      %User{} = user ->
        {encoded, token} = UserToken.build_email_token(user, "magic_link")
        Repo.insert!(token)
        UserNotifier.deliver_magic_link_instructions(user, url_fun.(encoded))

      _ ->
        :ok
    end
  end

  @doc """
  Consumes a magic-link token: verifies it, burns every outstanding magic-link
  token for that user (single-use), and returns the user to log in. Returns
  `{:ok, user}`, `{:error, :suspended}`, or `:error` for a bad/expired token.
  """
  def consume_magic_link(encoded_token) do
    with {:ok, query} <- UserToken.verify_email_token_query(encoded_token, "magic_link"),
         %User{} = user <- Repo.one(query) do
      {:ok, _} =
        Repo.transaction(
          Ecto.Multi.new()
          |> Ecto.Multi.delete_all(
            :tokens,
            UserToken.by_user_and_contexts_query(user, ["magic_link"])
          )
        )

      if User.suspended?(user) do
        {:error, :suspended}
      else
        {:ok, user}
      end
    else
      _ -> :error
    end
  end

  def authenticate(username, password) do
    user = get_user_by_username(username)

    case user do
      nil ->
        {:error, "Invalid username or password"}

      user ->
        cond do
          not Bcrypt.verify_pass(password, user.password_hash) ->
            {:error, "Invalid username or password"}

          User.suspended?(user) ->
            {:error, "This account has been suspended."}

          true ->
            {:ok, user}
        end
    end
  end

  @doc "Whether the user's role grants the given capability (see User.can?/2)."
  def can?(user, capability), do: User.can?(user, capability)

  def admin?(user), do: User.admin?(user)

  @doc "Role strings the admin UI may assign. Excludes super_admin (mix task only)."
  def roles, do: User.assignable_roles()

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
      case User.password_changeset(user, %{password: new_password}) do
        %Ecto.Changeset{valid?: true} = changeset ->
          password_hash = Ecto.Changeset.get_change(changeset, :password_hash)

          user
          |> User.changeset(%{password_hash: password_hash})
          |> Repo.update()

        changeset ->
          message =
            changeset
            |> Ecto.Changeset.traverse_errors(&interpolate_error/1)
            |> Map.get(:password, ["is invalid"])
            |> Enum.join(", ")

          {:error, message}
      end
    end
  end

  defp interpolate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  # Base32's alphabet (A-Z2-7) omits a digit in ~6% of draws, which would fail
  # the same strength rule this password is meant to satisfy — retry until it does.
  defp generate_temp_password do
    password = :crypto.strong_rand_bytes(10) |> Base.encode32(padding: false)
    if User.valid_password?(password), do: password, else: generate_temp_password()
  end
end
