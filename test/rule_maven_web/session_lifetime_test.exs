defmodule RuleMavenWeb.SessionLifetimeTest do
  use ExUnit.Case, async: false

  alias RuleMavenWeb.SessionLifetime

  @day 86_400
  @now 1_800_000_000

  test "sign-on sessions last 7 days" do
    until = SessionLifetime.sso_until(@now)
    assert until == @now + 7 * @day
    assert SessionLifetime.valid?(until, @now, @now + 7 * @day - 1)
    refute SessionLifetime.valid?(until, @now, @now + 7 * @day)
  end

  test "password sessions don't expire while sign-on is off" do
    Application.delete_env(:rule_maven, :oidc)
    assert SessionLifetime.valid?(nil, @now - 365 * @day, @now)
    assert SessionLifetime.valid?(nil, nil, @now)
  end

  test "once sign-on is on, password sessions get a grace period from their sign-in" do
    RuleMaven.FakeOidc.configure()
    grace = SessionLifetime.password_grace_days() * @day
    assert SessionLifetime.valid?(nil, @now - grace + 1, @now)
    refute SessionLifetime.valid?(nil, @now - grace, @now)
    refute SessionLifetime.valid?(nil, nil, @now)
  end
end
