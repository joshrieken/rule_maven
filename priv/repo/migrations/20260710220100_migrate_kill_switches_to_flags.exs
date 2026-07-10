defmodule RuleMaven.Repo.Migrations.MigrateKillSwitchesToFlags do
  use Ecto.Migration
  import Ecto.Query

  # Data migration: copy the two hand-rolled kill switches from app_settings
  # into fun_with_flags, INVERTING polarity. Old "disabled"=true  => flag OFF.
  #
  # Verified in place against dev: FunWithFlags.enable/1 and .disable/1 crash
  # here (GenServer.call to FunWithFlags.Store.Cache / Notifications.PhoenixPubSub
  # -> "no process ... application isn't started") because `mix ecto.migrate`
  # does not boot the app's OTP supervision tree (no PubSub, no flags cache).
  # So this writes directly to the `fun_with_flags_toggles` table instead of
  # going through the FunWithFlags API.
  #
  # NOTE: the boolean gate's `target` column is "_fwf_none" (see
  # FunWithFlags.Store.Persistent.Ecto.Record.serialize_target(nil)), not
  # "_fwf_boolean". Using the wrong constant creates a second row alongside
  # any row FunWithFlags itself later writes for the same flag/gate_type,
  # and FunWithFlags ORs multiple boolean gates together — so a stray
  # "_fwf_boolean" row stuck at enabled:true can leave a flag looking ON
  # even after a real .disable/1 writes enabled:false to "_fwf_none".
  def up do
    flush()
    migrate("asks_disabled", :asks)
    migrate("email_disabled", :outbound_email)
  end

  def down do
    flush()
    # Non-destructive: leave the flags in place. app_settings rows were never removed.
    :ok
  end

  defp migrate(setting_key, flag) do
    disabled? =
      repo().one(from(s in "app_settings", where: s.key == ^setting_key, select: s.value)) ==
        "true"

    # enabled == working == NOT disabled
    put_boolean(repo(), flag, not disabled?)
  end

  defp put_boolean(repo, flag, enabled?) do
    repo.insert_all(
      "fun_with_flags_toggles",
      [
        %{
          flag_name: to_string(flag),
          gate_type: "boolean",
          target: "_fwf_none",
          enabled: enabled?
        }
      ],
      on_conflict: {:replace, [:enabled]},
      conflict_target: [:flag_name, :gate_type, :target]
    )
  end
end
