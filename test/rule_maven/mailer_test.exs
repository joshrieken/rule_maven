defmodule RuleMaven.MailerTest do
  use RuleMaven.DataCase, async: false

  import Swoosh.TestAssertions

  alias RuleMaven.{Mailer, Settings}
  alias RuleMaven.Users.UserNotifier

  defp email(subject \\ "hello") do
    Swoosh.Email.new()
    |> Swoosh.Email.to("player@example.com")
    |> Swoosh.Email.from({"Rule Maven", "no-reply@rulemaven.app"})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body("body")
  end

  test "delivers via the configured Test adapter" do
    assert {:ok, _} = Mailer.deliver_email(email())
    assert_email_sent(subject: "hello")
  end

  test "kill switch skips delivery but succeeds" do
    {:ok, _} = RuleMaven.Flags.disable(:outbound_email)
    on_exit(fn -> FunWithFlags.clear(:outbound_email) end)

    assert {:ok, :email_disabled} = Mailer.deliver_email(email())
    assert_no_email_sent()
  end

  test "email settings round-trip with defaults" do
    refute Settings.email_disabled?()
    refute Settings.mail_dev_live?()
    assert Settings.mail_from() == "no-reply@rulemaven.app"

    {:ok, _} = Settings.set_mail_from("  hello@rulemaven.app  ")
    assert Settings.mail_from() == "hello@rulemaven.app"

    {:ok, _} = Settings.put("mail_from", "")
    assert Settings.mail_from() == "no-reply@rulemaven.app"

    {:ok, _} = Settings.set_mail_dev_live(true)
    assert Settings.mail_dev_live?()
  end

  test "notifier sends from the configured mail_from" do
    {:ok, _} = Settings.set_mail_from("custom@rulemaven.app")

    user = %RuleMaven.Users.User{email: "player@example.com", username: "player"}
    assert {:ok, _} = UserNotifier.deliver_confirmation_instructions(user, "http://x/confirm/t")

    assert_email_sent(fn sent ->
      assert sent.from == {"Rule Maven", "custom@rulemaven.app"}
      assert sent.subject =~ "Confirm"
    end)
  end
end
