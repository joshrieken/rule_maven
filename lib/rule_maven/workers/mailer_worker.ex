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
  # (It also exports `from/2`, which collides with Ecto.Query's — hence the
  # qualified Ecto.Query call in scrub_args/1.)
  import Swoosh.Email, except: [new: 0, new: 1]

  require Ecto.Query

  alias RuleMaven.{Mailer, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case Mailer.deliver_email_now(rebuild(args)) do
      {:ok, _} ->
        scrub_args(job)
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # SECURITY: auth email bodies embed tokenized sign-in/reset/confirm URLs, and
  # Oban persists `args` verbatim in `oban_jobs` for the whole prune window —
  # a DB read (or backup) days later would still hold live-looking magic-link
  # URLs. Once delivery succeeded the args have done their job, so overwrite
  # them in place (keep the subject for debuggability). Oban's own post-perform
  # bookkeeping touches state/completed_at, not args, so this write survives.
  #
  # Only on success: a retryable failure still needs the args to rebuild the
  # email. Failed/discarded jobs therefore keep their args until the job row is
  # pruned — acceptable because the tokens self-expire regardless (magic link
  # 15 min, password reset 24 h, email confirm 7 days; see UserToken).
  defp scrub_args(%Oban.Job{id: id, args: args}) when is_integer(id) do
    Repo.update_all(
      Ecto.Query.from(j in Oban.Job, where: j.id == ^id),
      set: [args: %{"scrubbed" => true, "subject" => args["subject"]}]
    )

    :ok
  end

  # Oban.Testing's perform_job builds an unpersisted job (id: nil) — nothing to scrub.
  defp scrub_args(_job), do: :ok

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
