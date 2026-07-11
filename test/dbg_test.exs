defmodule DbgTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures
  alias RuleMaven.Games

  test "dbg" do
    game = game_fixture(%{name: "Crew Game"})
    {:ok, member} = RuleMaven.Users.create_user(%{username: "m1x", email: "m1x@t.com", password: "password1234"})
    group = group_fixture(member)
    {:ok, q} = Games.log_question(%{game_id: game.id, user_id: member.id, group_id: group.id,
      question: "SECRETWORDING will Dave smuggler get caught", cleaned_question: "Can a smuggler be caught?",
      answer: "Yes, on a failed roll.", visibility: "private", citation_valid: true, pooled: true, browsable: false})
    conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => member.id})
    {:ok, view, _} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}")
    html = render(view)
    st = :sys.get_state(view.pid)
    a = st.socket.assigns
    File.write!("/tmp/out.html", html)
    IO.inspect(a.threads, label: "threads")
    IO.inspect(a.active_thread_id, label: "active")
    IO.inspect(a.conversation, label: "conv")
    IO.puts("cleaned? #{html =~ "Can a smuggler be caught?"} raw? #{html =~ "SECRETWORDING"}")
  end
end
