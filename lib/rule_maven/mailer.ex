defmodule RuleMaven.Mailer do
  @moduledoc """
  Outbound mail. Adapter is configured per-env (see config/*.exs): Local in dev
  (preview at `/dev/mailbox`), Test in test, a real adapter in prod.
  """
  use Swoosh.Mailer, otp_app: :rule_maven
end
