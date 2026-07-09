defmodule RuleMaven.Mailer do
  @moduledoc """
  Outbound mail. All sends go through `deliver_email/1`, the single choke point
  that applies the kill switch and picks the adapter:

    * `Settings.email_disabled?` → skipped (email is best-effort; callers succeed)
    * test → configured Test adapter (assert_email_sent keeps working)
    * dev without `mail_dev_live` → configured Local adapter (`/dev/mailbox`)
    * `RESEND_API_KEY` set → Resend
    * no key → skipped with a warning, never a crash
  """
  use Swoosh.Mailer, otp_app: :rule_maven

  require Logger

  alias RuleMaven.Settings

  @doc "Delivers an email subject to the kill switch and adapter selection above."
  def deliver_email(%Swoosh.Email{} = email) do
    cond do
      Settings.email_disabled?() ->
        Logger.info("email disabled by kill switch: skipping #{describe(email)}")
        {:ok, :email_disabled}

      env() == :test ->
        deliver(email)

      env() == :dev and not Settings.mail_dev_live?() ->
        deliver(email)

      api_key = System.get_env("RESEND_API_KEY") ->
        deliver(email, adapter: Resend.Swoosh.Adapter, api_key: api_key)

      true ->
        Logger.warning(
          "RESEND_API_KEY not set: skipping #{describe(email)}. " <>
            "Outbound email is unconfigured."
        )

        {:ok, :email_unconfigured}
    end
  end

  defp env, do: Application.get_env(:rule_maven, :env)

  defp describe(%Swoosh.Email{subject: subject}), do: "email #{inspect(subject)}"
end
