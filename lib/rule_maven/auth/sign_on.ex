defmodule RuleMaven.Auth.SignOn do
  @moduledoc """
  Who a single sign-on is (the protocol is `RuleMaven.Auth.Oidc`). People are linked by
  `users.oidc_sub` alone:

    * the token's `groups` must include the users group or the admin group, at every sign-in;
    * found by `oidc_sub` → that account; else a NEW account (never admin unless in the admin
      group, no password). Never matched to an existing account by email or username: existing
      accounts link while signed in (`link/3`, the "Link your … account" button) or by the
      operator (`link_user/2`, `mix rule_maven.link_sso`);
    * role re-synced from group membership at every sign-in. With a super-admin group
      (`superadmin_group`, PLATFORM.md §2), admins also in it are "super_admin", the rest "admin" or
      "user"; the last super admin who signs on here is never demoted. Without one, "admin" ⇄ "user"
      and a super admin's role is server-only (`mix rule_maven.grant_superadmin`), never changed here.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Repo
  alias RuleMaven.Users.{AuthCache, User}

  @type claims :: map()
  @type opts :: [
          group: String.t() | nil,
          admin_group: String.t() | nil,
          superadmin_group: String.t() | nil
        ]

  @doc "The account linked to this sign-on id, if any."
  @spec get_user_by_sub(String.t()) :: User.t() | nil
  def get_user_by_sub(sub) when is_binary(sub), do: Repo.get_by(User, oidc_sub: sub)

  @doc """
  Signs someone in from verified ID-token claims. Returns `{:ok, user}` or `{:error, message}`
  (safe to show).
  """
  @spec sign_in(claims(), opts()) :: {:ok, User.t()} | {:error, String.t()}
  def sign_in(claims, opts) do
    with {:ok, sub} <- fetch_sub(claims),
         {:ok, level} <- check_groups(claims, opts) do
      case get_user_by_sub(sub) do
        nil -> create(sub, claims, level)
        %User{} = user -> existing(user, level)
      end
    end
  end

  @doc """
  Links the signed-in `user` to the sign-on account in `claims` (the same group check applies,
  and the role is synced as at sign-in). Refused if that sign-on account already belongs to
  someone else here.
  """
  @spec link(User.t(), claims(), opts()) :: {:ok, User.t()} | {:error, String.t()}
  def link(%User{} = user, claims, opts) do
    with {:ok, sub} <- fetch_sub(claims),
         {:ok, level} <- check_groups(claims, opts),
         {:ok, linked} <- put_sub(user, sub) do
      existing(linked, level)
    end
  end

  @doc """
  Operator migration: links an existing account to a sign-on id (the provider's `sub` for that
  person, shown as the user's UID in Authentik's admin), or unlinks it with nil. No group check:
  that happens when they sign in.
  """
  @spec link_user(User.t(), String.t() | nil) :: {:ok, User.t()} | {:error, String.t()}
  def link_user(%User{} = user, sub) when is_binary(sub) do
    case String.trim(sub) do
      "" -> {:error, "The sign-on id is empty."}
      sub -> put_sub(user, sub)
    end
  end

  def link_user(%User{} = user, nil) do
    user |> User.oidc_link_changeset(nil) |> Repo.update() |> bust() |> describe_error()
  end

  defp put_sub(%User{oidc_sub: sub} = user, sub), do: {:ok, user}

  defp put_sub(%User{} = user, sub) do
    case get_user_by_sub(sub) do
      %User{id: id} when id != user.id ->
        {:error, "That account is already linked to a different user here."}

      _ ->
        user
        |> User.oidc_link_changeset(sub)
        |> Repo.update()
        |> bust()
        |> describe_error()
    end
  end

  defp fetch_sub(%{"sub" => sub}) when is_binary(sub) and sub != "" and byte_size(sub) <= 255,
    do: {:ok, sub}

  defp fetch_sub(_claims), do: {:error, "The sign-in service sent no account id."}

  # In the users group or the admin group (admins may use the app too). Returns `{level, managed?}`:
  # the level the groups give (:super_admin, :admin or :user) and whether a super-admin group decides
  # super admins (without one, a super admin's role is the server's).
  defp check_groups(claims, opts) do
    groups =
      case claims["groups"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    group = opts[:group]
    managed? = is_binary(opts[:superadmin_group])

    cond do
      member?(groups, opts[:admin_group]) and member?(groups, opts[:superadmin_group]) ->
        {:ok, {:super_admin, managed?}}

      member?(groups, opts[:admin_group]) ->
        {:ok, {:admin, managed?}}

      not is_binary(group) or group in groups ->
        {:ok, {:user, managed?}}

      true ->
        {:error, "Your account isn't allowed in yet. Ask the admin to add you to \"#{group}\"."}
    end
  end

  defp member?(groups, group), do: is_binary(group) and group in groups

  defp existing(%User{} = user, level) do
    if User.suspended?(user) do
      {:error, "This account has been suspended."}
    else
      user |> sync(level) |> Repo.update() |> bust() |> describe_error()
    end
  end

  # Role follows the admin group; the account counts as email-confirmed (the provider's
  # operator made it), since confirmation emails are off while sign-on is on.
  defp sync(%User{} = user, level) do
    role = role_for(user, level)

    changes = if user.role == role, do: %{}, else: %{role: role}

    changes =
      if user.email_confirmed_at, do: changes, else: Map.put(changes, :email_confirmed_at, now())

    Ecto.Changeset.change(user, changes)
  end

  defp role_for(_user, {:super_admin, _}), do: "super_admin"

  defp role_for(%User{} = user, {level, managed?}) do
    # Without a super-admin group a super admin's role is the server's; with one, the last super
    # admin who signs on here stays one (the group may just be empty for now).
    if User.super_admin?(user) and (not managed? or not other_signed_on_super_admin?(user)),
      do: user.role,
      else: Atom.to_string(level)
  end

  # Another super admin who can sign on (a service account without a sign-on id can't step in).
  defp other_signed_on_super_admin?(%User{id: id}) do
    Repo.exists?(
      from u in User,
        where:
          u.id != ^id and u.role in ^User.roles_with_capability(:superadmin) and
            not is_nil(u.oidc_sub)
    )
  end

  defp create(sub, claims, {level, _managed?}) do
    email = free_email(claims["email"])

    %{
      username: free_username(claims),
      email: email,
      role: if(level == :user, do: "user", else: "admin"),
      oidc_sub: sub,
      email_confirmed_at: now()
    }
    |> User.sign_on_changeset()
    # (Validated as an admin: super_admin is never an assignable role, only the groups give it.)
    |> then(
      &if(level == :super_admin,
        do: Ecto.Changeset.put_change(&1, :role, "super_admin"),
        else: &1
      )
    )
    |> Repo.insert()
    |> describe_error()
  end

  # The provider's address, unless an account here already has it (then the new account has
  # none: matching by email is exactly the auto-link we never do).
  defp free_email(email) when is_binary(email) do
    email = String.trim(email)

    cond do
      email == "" or String.length(email) > 160 -> nil
      RuleMaven.Users.get_user_by_email(email) -> nil
      true -> email
    end
  end

  defp free_email(_), do: nil

  # preferred_username (or name), made unique with a numeric suffix: an existing account with
  # the same username is someone else until linked.
  defp free_username(claims) do
    base =
      [claims["preferred_username"], claims["name"]]
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
      |> case do
        nil -> "player"
        name -> name |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 40)
      end

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not username_taken?(&1)))
  end

  defp username_taken?(name) do
    Repo.exists?(
      from u in User, where: fragment("lower(?)", u.username) == ^String.downcase(name)
    )
  end

  defp bust({:ok, %User{id: id}} = result) do
    AuthCache.invalidate(id)
    result
  end

  defp bust(result), do: result

  defp describe_error({:ok, user}), do: {:ok, user}

  defp describe_error({:error, %Ecto.Changeset{} = changeset}) do
    if Keyword.has_key?(changeset.errors, :oidc_sub) do
      {:error, "That account is already linked to a different user here."}
    else
      {:error, "Couldn't set up your account here. Try again, or ask the admin."}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
