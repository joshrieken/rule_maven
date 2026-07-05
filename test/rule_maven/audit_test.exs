defmodule RuleMaven.AuditTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Audit, Users}

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{username: name, email: "#{name}@test.com", password: "testpass1234"})

    u
  end

  describe "log/3 + list/1" do
    test "records an action with actor snapshot and target" do
      admin = user_fixture("auditor")
      target = user_fixture("victim")

      assert :ok =
               Audit.log(admin, "user.suspend",
                 target_type: "user",
                 target_id: target.id,
                 target_label: target.username,
                 metadata: %{reason: "spam"}
               )

      [entry] = Audit.list()
      assert entry.actor_id == admin.id
      assert entry.actor_username == "auditor"
      assert entry.action == "user.suspend"
      assert entry.target_type == "user"
      assert entry.target_id == target.id
      assert entry.metadata["reason"] == "spam"
    end

    test "actor snapshot survives actor deletion" do
      admin = user_fixture("ghost")
      Audit.log(admin, "role.demote", target_type: "user", target_id: 1)
      {:ok, _} = Users.delete_user(admin)

      [entry] = Audit.list()
      assert entry.actor_id == nil
      assert entry.actor_username == "ghost"
    end

    test "filters by action and respects limit, newest first" do
      admin = user_fixture("a")
      Audit.log(admin, "user.suspend", target_type: "user", target_id: 1)
      Audit.log(admin, "question.delete", target_type: "question", target_id: 2)
      Audit.log(admin, "user.suspend", target_type: "user", target_id: 3)

      suspends = Audit.list(action: "user.suspend")
      assert length(suspends) == 2
      assert Enum.all?(suspends, &(&1.action == "user.suspend"))

      assert length(Audit.list(limit: 1)) == 1
      # Newest first: last logged suspend (target 3) leads its filtered set.
      assert hd(suspends).target_id == 3
    end

    test "blank action filter returns everything" do
      admin = user_fixture("b")
      Audit.log(admin, "user.create", target_type: "user", target_id: 9)
      assert length(Audit.list(action: "")) == 1
    end

    test "nil actor (system action) is allowed" do
      assert :ok = Audit.log(nil, "system.cleanup")
      [entry] = Audit.list()
      assert entry.actor_id == nil
      assert entry.actor_username == nil
    end

    test "actions/0 returns distinct sorted verbs" do
      admin = user_fixture("c")
      Audit.log(admin, "user.suspend")
      Audit.log(admin, "user.suspend")
      Audit.log(admin, "role.promote")

      assert Audit.actions() == ["role.promote", "user.suspend"]
    end
  end

  describe "question_history/2" do
    test "matches on exact game_id + question text, newest first" do
      admin = user_fixture("mod")

      Audit.log(admin, "question.delete",
        target_type: "question",
        target_id: 1,
        metadata: %{game_id: 42, question: "How does combat work?", answer: "First answer"}
      )

      Audit.log(admin, "question.delete",
        target_type: "question",
        target_id: 2,
        metadata: %{game_id: 42, question: "How does combat work?", answer: "Second answer"}
      )

      # Different game, same question text — must not match.
      Audit.log(admin, "question.delete",
        target_type: "question",
        target_id: 3,
        metadata: %{game_id: 99, question: "How does combat work?", answer: "Other game"}
      )

      # Different question text, same game — must not match.
      Audit.log(admin, "question.delete",
        target_type: "question",
        target_id: 4,
        metadata: %{game_id: 42, question: "How does setup work?", answer: "Unrelated"}
      )

      [newest, oldest] = Audit.question_history(42, "How does combat work?")
      assert newest.metadata["answer"] == "Second answer"
      assert oldest.metadata["answer"] == "First answer"
    end

    test "returns [] when nothing matches" do
      assert Audit.question_history(1, "Nothing asked yet") == []
    end
  end
end
