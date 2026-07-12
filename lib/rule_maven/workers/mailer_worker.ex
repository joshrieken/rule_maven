defmodule RuleMaven.Workers.MailerWorker do
  @moduledoc """
  Delivers one outbound email in the background.

  Auth emails (magic link, password reset, confirmation) used to send
  synchronously in-request through the Resend HTTP API — a slow provider held
  the controller open, and the extra latency on the "account exists" branch
  was a timing oracle for account enumeration. Enqueuing makes both branches
  return in roughly constant time and gives delivery Oban's durability +
  retries (email is fire-and-forget → Oban, per project convention).

  Args carry only primitives (recipients, from, subject, bodies) — a
  `Swoosh.Email` struct can't ride through JSON — and `perform/1` rebuilds the
  struct and hands it to the existing synchronous choke point,
  `Mailer.deliver_email_now/1`, which still applies the kill switch and
  adapter selection at delivery time.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  # Swoosh.Email and Oban.Worker both export `new` — Oban's job constructor
  # wins locally, so Swoosh's is excluded and called by full name in rebuild/1.
  import Swoosh.Email, except: [new: 0, new: 1]

  alias RuleMaven.Mailer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Mailer.deliver_email_now(rebuild(args)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Serializes the email to primitive args and inserts the job. Returns
  `{:ok, job}` or `{:error, changeset}`.
  """
  def enqueue(%Swoosh.Email{} = email) do
    %{
      "to" => Enum.map(email.to, fn {name, addr} -> [name, addr] end),
      "from" => email.from |> Tuple.to_list(),
      "subject" => email.subject,
      "text_body" => email.text_body,
      "html_body" => email.html_body
    }
    |> new()
    |> Oban.insert()
  end

  defp rebuild(args) do
    email =
      Swoosh.Email.new()
      |> to(Enum.map(args["to"], fn [name, addr] -> {name, addr} end))
      |> from(List.to_tuple(args["from"]))
      |> subject(args["subject"])

    email = if args["text_body"], do: text_body(email, args["text_body"]), else: email
    if args["html_body"], do: html_body(email, args["html_body"]), else: email
  end
end
