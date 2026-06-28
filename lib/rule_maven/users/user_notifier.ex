defmodule RuleMaven.Users.UserNotifier do
  @moduledoc "Builds and delivers transactional emails to users."

  import Swoosh.Email
  alias RuleMaven.Mailer

  # Sender address. SendGrid rejects unverified senders, so prod overrides this
  # via MAIL_FROM to match a verified sender identity.
  defp from_address do
    {"Rule Maven", System.get_env("MAIL_FROM") || "no-reply@rulemaven.app"}
  end

  defp deliver(to, subject, body) do
    email =
      new()
      |> to(to)
      |> from(from_address())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email), do: {:ok, email}
  end

  @doc "Sends the email-confirmation link."
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your Rule Maven email", """

    Hi #{user.username},

    Confirm your email address to unlock community voting on Rule Maven:

    #{url}

    If you didn't create this account, ignore this email.
    """)
  end

  @doc "Sends the password-reset link."
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset your Rule Maven password", """

    Hi #{user.username},

    Someone asked to reset the password for your Rule Maven account. Use this
    link to choose a new one (it expires in 24 hours):

    #{url}

    If you didn't request this, ignore this email — your password won't change.
    """)
  end
end
