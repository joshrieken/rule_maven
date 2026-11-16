defmodule RuleMaven.Auth.SignOn do
  @moduledoc """
  Who a single sign-on is (the protocol is `RuleMaven.Auth.Oidc`). People are linked by
  `users.oidc_sub` alone:

    * the token's `groups` must include the users group or the admin group, at every sign-in;
    * found by `oidc_sub` → that account; else a NEW account (never admin unless in the admin
      group, no password). Never matched to an existing account by email or username: existing
      accounts link while signed in (`link/3`, the "Link your … account" button) or by the
      operator (`link_user/2`, `mix rule_maven.link_sso`);
    * role re-synced from admin-group membership at every sign-in ("admin" ⇄ "user"); a
      super admin's role is server-only and never changed here.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Repo
  alias RuleMaven.Users.{AuthCache, User}

  @type claims :: map()
  @type opts :: [group: String.t() | nil, admin_group: String.t() | nil]

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
         {:ok, admin?} <- check_groups(claims, opts) do
      case get_user_by_sub(sub) do
        nil -> create(sub, claims, admin?)
        %User{} = user -> existing(user, admin?)
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
         {:ok, admin?} <- check_groups(claims, opts),
         {:ok, linked} <- put_sub(user, sub) do
      existing(linked, admin?)
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

  # In the users group or the admin group (admins may use the app too). Returns whether admin.
  defp check_groups(claims, opts) do
    groups =
      case claims["groups"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    group = opts[:group]
    admin_group = opts[:admin_group]
    admin? = is_binary(admin_group) and admin_group in groups

    cond do
      admin? ->
        {:ok, true}

      is_binary(group) and group in groups ->
        {:ok, false}

      not is_binary(group) ->
        {:ok, false}

      true ->
        {:error, "Your account isn't allowed in yet. Ask the admin to add you to \"#{group}\"."}
    end
  end

  defp existing(%User{} = user, admin?) do
    if User.suspended?(user) do
      {:error, "This account has been suspended."}
    else
      user |> sync(admin?) |> Repo.update() |> bust() |> describe_error()
    end
  end

  # Role follows the admin group; the account counts as email-confirmed (the provider's
  # operator made it), since confirmation emails are off while sign-on is on.
  defp sync(%User{} = user, admin?) do
    role =
      cond do
        User.super_admin?(user) -> user.role
        admin? -> "admin"
        true -> "user"
      end

    changes = if user.role == role, do: %{}, else: %{role: role}

    changes =
      if user.email_confirmed_at, do: changes, else: Map.put(changes, :email_confirmed_at, now())

    Ecto.Changeset.change(user, changes)
  end

  defp create(sub, claims, admin?) do
    email = free_email(claims["email"])

    %{
      username: free_username(claims),
      email: email,
      role: if(admin?, do: "admin", else: "user"),
      oidc_sub: sub,
      email_confirmed_at: now()
    }
    |> User.sign_on_changeset()
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
