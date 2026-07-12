defmodule RuleMaven.Mailer do
  @moduledoc """
  Outbound mail. All sends go through `deliver_email/1`, which enqueues a
  background `MailerWorker` job (or falls through synchronously in tests /
  when opted out — see `deliver_email/1`). Actual delivery happens in
  `deliver_email_now/1`, the single choke point that applies the kill switch
  and picks the adapter:

    * `:outbound_email` flag disabled → skipped (email is best-effort; callers succeed)
    * test → configured Test adapter (assert_email_sent keeps working)
    * dev without `mail_dev_live` → configured Local adapter (`/dev/mailbox`)
    * Resend key set (Settings, falls back to `RESEND_API_KEY` env) → Resend
    * no key → skipped with a warning, never a crash
  """
  use Swoosh.Mailer, otp_app: :rule_maven

  require Logger

  alias RuleMaven.Settings

  @doc """
  Delivers an email. Normally enqueues a `MailerWorker` job (`{:ok, job}`) so
  the caller — often an auth controller mid-request — never waits on the mail
  provider's HTTP round trip; that latency was also a timing oracle for
  account enumeration (only the "account exists" branch paid it). Delivery is
  durable and retried by Oban; the worker funnels back into
  `deliver_email_now/1`.

  Falls back to the synchronous path when Oban runs in `:manual` testing mode
  (the test suite's Swoosh assertions read the in-process mailbox), or when
  `config :rule_maven, :mail_async, false` opts out.
  """
  def deliver_email(%Swoosh.Email{} = email) do
    if async?() do
      RuleMaven.Workers.MailerWorker.enqueue(email)
    else
      deliver_email_now(email)
    end
  end

  defp async? do
    Application.get_env(:rule_maven, :mail_async, true) and
      Application.get_env(:rule_maven, Oban)[:testing] != :manual
  end

  @doc "Synchronously delivers, subject to the kill switch and adapter selection above."
  def deliver_email_now(%Swoosh.Email{} = email) do
    cond do
      not RuleMaven.Flags.enabled?(:outbound_email) ->
        Logger.info("email disabled by kill switch: skipping #{describe(email)}")
        {:ok, :email_disabled}

      env() == :test ->
        deliver(email)

      env() == :dev and not Settings.mail_dev_live?() ->
        deliver(email)

      api_key = Settings.resend_api_key() ->
        deliver(email, adapter: Resend.Swoosh.Adapter, api_key: api_key)

      true ->
        Logger.warning(
          "Resend API key not set (Settings or RESEND_API_KEY): skipping #{describe(email)}. " <>
            "Outbound email is unconfigured."
        )

        {:ok, :email_unconfigured}
    end
  end

  defp env, do: Application.get_env(:rule_maven, :env)

  defp describe(%Swoosh.Email{subject: subject}), do: "email #{inspect(subject)}"
end
