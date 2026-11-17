defmodule Lccz.Groups do
  @moduledoc """
  What a person's groups at the sign-in service make them in an app (PLATFORM.md §2), re-checked
  at every sign-in: in the users group or the admin group (admins may use the app too), and with a
  super-admin group configured, admins also in it are super admins.
  """

  @typedoc "`managed?`: a super-admin group decides super admins (without one, the app's own say)."
  @type level :: {:super_admin | :admin | :user, managed? :: boolean()}

  @doc """
  The level the ID token's `groups` give, or an error (safe to show) when they let nobody in.
  `groups`: the app's `Lccz.Oidc.Settings`, or a keyword/map with `:group`, `:admin_group` and
  `:superadmin_group`.
  """
  @spec level(map(), map() | keyword()) :: {:ok, level()} | {:error, String.t()}
  def level(claims, groups_config) do
    s = %{
      group: get(groups_config, :group),
      admin_group: get(groups_config, :admin_group),
      superadmin_group: get(groups_config, :superadmin_group)
    }

    groups =
      case claims["groups"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    managed? = is_binary(s.superadmin_group)
    admin? = member?(groups, s.admin_group)

    cond do
      admin? and member?(groups, s.superadmin_group) -> {:ok, {:super_admin, managed?}}
      admin? -> {:ok, {:admin, managed?}}
      not is_binary(s.group) or s.group in groups -> {:ok, {:user, managed?}}
      true -> {:error, "Your account isn't allowed in yet. Ask the admin to add you to \"#{s.group}\"."}
    end
  end

  defp member?(groups, group), do: is_binary(group) and group in groups

  defp get(config, key) when is_list(config), do: Keyword.get(config, key)
  defp get(config, key), do: Map.get(config, key)
end
