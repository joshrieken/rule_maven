defmodule RuleMaven.Users.UserNotifier do
  @moduledoc "Builds and delivers transactional emails to users."

  import Swoosh.Email
  alias RuleMaven.Mailer

  require Logger

  # Sender address. Resend rejects senders from unverified domains, so prod
  # sets the admin "mail from" setting to an address on the verified domain.
  defp from_address do
    {"Rule Maven", RuleMaven.Settings.mail_from()}
  end

  defp deliver(to, subject, body) do
    email =
      new()
      |> to(to)
      |> from(from_address())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver_email(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} ->
        Logger.error("mail delivery failed for #{inspect(to)}: #{inspect(reason)}")
        {:error, reason}
    end
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

  @doc "Sends the passwordless sign-in link."
  def deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Your Rule Maven sign-in link", """

    Hi #{user.username},

    Use this link to sign in without a password (it expires in 15 minutes and
    works once):

    #{url}

    If you didn't request this, ignore this email — no one can sign in without
    clicking the link above.
    """)
  end
end
