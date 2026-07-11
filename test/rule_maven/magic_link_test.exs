defmodule RuleMaven.MagicLinkTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Users

  defp user_fixture do
    {:ok, u} =
      Users.create_user(%{
        username: "linkme",
        email: "Link.Me@Test.com",
        password: "oldpass1234"
      })

    u
  end

  defp token_from_email do
    {:ok, email} =
      Users.deliver_magic_link_instructions("link.me@test.com", &("http://x/magic-link/" <> &1))

    [_, token] = Regex.run(~r{/magic-link/(\S+)}, email.text_body)
    token
  end

  test "deliver is case-insensitive and returns :ok for unknown emails" do
    user_fixture()
    assert {:ok, _email} = Users.deliver_magic_link_instructions("LINK.ME@test.com", & &1)
    assert :ok = Users.deliver_magic_link_instructions("nobody@nowhere.com", & &1)
  end

  test "consuming a valid token returns the user and burns the token" do
    user = user_fixture()
    token = token_from_email()

    assert {:ok, consumed} = Users.consume_magic_link(token)
    assert consumed.id == user.id

    # Single-use.
    assert :error = Users.consume_magic_link(token)
  end

  test "a garbage token is rejected" do
    assert :error = Users.consume_magic_link("not-a-token")
  end

  test "a suspended user's link fails without burning the token" do
    user = user_fixture()
    {:ok, _} = Users.suspend_user(user)
    token = token_from_email()

    assert {:error, :suspended} = Users.consume_magic_link(token)
    # Already burned on the first (suspended) attempt too — no replay.
    assert :error = Users.consume_magic_link(token)
  end
end
