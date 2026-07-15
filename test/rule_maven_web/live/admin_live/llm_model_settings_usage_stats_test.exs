defmodule RuleMavenWeb.AdminLive.LlmModelSettingsUsageStatsTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Settings

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(role) do
    create_role = if role == "super_admin", do: "admin", else: role

    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: create_role
      })

    if role == "super_admin" do
      {:ok, u} = RuleMaven.Users.set_super_admin(u, true)
      u
    else
      u
    end
  end

  describe "LLM settings page" do
    test "renders and saves critic + cheap model selects", %{conn: conn} do
      {:ok, view, html} = conn |> login(user("super_admin")) |> live(~p"/admin/llm")

      assert html =~ "Grounding critic model"
      assert html =~ "Cheap-task model"

      view
      |> form("#llm-settings-form", %{
        "llm_provider" => "openrouter",
        "llm_critic_model_openrouter" => "google/gemini-2.5-flash-lite",
        "llm_cheap_model_openrouter" => "google/gemini-2.5-flash"
      })
      |> render_submit()

      assert Settings.get("llm_critic_model_openrouter") == "google/gemini-2.5-flash-lite"
      assert Settings.get("llm_cheap_model_openrouter") == "google/gemini-2.5-flash"
    after
      Settings.delete("llm_critic_model_openrouter")
      Settings.delete("llm_cheap_model_openrouter")
    end

    test "blank critic select clears the override", %{conn: conn} do
      Settings.put("llm_critic_model_openrouter", "google/gemini-2.5-flash-lite")
      {:ok, view, _html} = conn |> login(user("super_admin")) |> live(~p"/admin/llm")

      view
      |> form("#llm-settings-form", %{
        "llm_provider" => "openrouter",
        "llm_critic_model_openrouter" => ""
      })
      |> render_submit()

      assert Settings.get("llm_critic_model_openrouter") == nil
    after
      Settings.delete("llm_critic_model_openrouter")
    end
  end

  describe "ask_stats/1" do
    test "counts pool hits against total asks" do
      game = game_fixture()
      asker = user("user")

      for provider <- ["pool", "openrouter", "openrouter"] do
        {:ok, _} =
          RuleMaven.Games.log_question(%{
            game_id: game.id,
            user_id: asker.id,
            question: "Q #{provider} #{System.unique_integer([:positive])}?",
            answer: "A.",
            llm_provider: provider,
            promoted: false
          })
      end

      stats = RuleMaven.LLM.ask_stats(1)
      assert stats.asks >= 3
      assert stats.pool_hits >= 1
      assert stats.pool_hit_rate > 0.0 and stats.pool_hit_rate <= 1.0
    end
  end

  describe "usage dashboard" do
    test "shows $/question and pool hit rate", %{conn: conn} do
      {:ok, _view, html} = conn |> login(user("admin")) |> live(~p"/admin/usage")

      assert html =~ "$ / question"
      assert html =~ "Pool hit rate"
    end
  end
end
