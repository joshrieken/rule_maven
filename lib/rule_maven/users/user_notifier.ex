defmodule RuleMaven.Users.UserNotifier do
  @moduledoc "Builds and delivers transactional emails to users."

  import Swoosh.Email
  alias RuleMaven.Mailer

  @from {"Rule Maven", "no-reply@rulemaven.app"}

  defp deliver(to, subject, body) do
    email =
      new()
      |> to(to)
      |> from(@from)
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
end
