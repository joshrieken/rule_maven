defmodule RuleMaven.InviteCodesTest do
  use RuleMaven.DataCase

  alias RuleMaven.{InviteCodes, Repo, Users}

  setup do
    {:ok, gm} =
      Users.create_user(%{
        username: "invite_gm",
        email: "invite_gm@test.com",
        password: "testpass1234",
        role: "admin"
      })

    %{gm: gm}
  end

  describe "create invite code" do
    test "creates with defaults", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id)
      assert code.max_uses == 1
      assert code.use_count == 0
      assert code.active == true
      assert String.length(code.code) >= 8
    end

    test "creates with custom max_uses", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id, max_uses: 5)
      assert code.max_uses == 5
    end

    test "creates with expiry", %{gm: gm} do
      expiry = DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)
      {:ok, code} = InviteCodes.create_code(gm.id, expires_at: expiry)
      assert code.expires_at == expiry
    end

    test "generates unique codes", %{gm: gm} do
      {:ok, c1} = InviteCodes.create_code(gm.id)
      {:ok, c2} = InviteCodes.create_code(gm.id)
      assert c1.code != c2.code
    end
  end

  describe "validate invite code" do
    test "returns ok for valid code", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id)
      assert {:ok, _} = InviteCodes.validate_code(code.code)
    end

    test "returns error for nonexistent code", %{} do
      assert {:error, "Invalid invite code."} = InviteCodes.validate_code("noexist")
    end

    test "returns error for inactive code", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id)
      Repo.update!(Ecto.Changeset.change(code, active: false))

      assert {:error, "This invite code is no longer active."} =
               InviteCodes.validate_code(code.code)
    end

    test "returns error for expired code", %{gm: gm} do
      expiry = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, code} = InviteCodes.create_code(gm.id, expires_at: expiry)

      assert {:error, "This invite code has expired."} =
               InviteCodes.validate_code(code.code)
    end

    test "returns error when max uses reached", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id, max_uses: 1)
      Repo.update!(Ecto.Changeset.change(code, use_count: 1))

      assert {:error, "This invite code has reached its maximum uses."} =
               InviteCodes.validate_code(code.code)
    end

    test "nil code returns error", %{} do
      assert {:error, "Invalid invite code."} = InviteCodes.validate_code(nil)
    end

    test "empty string code returns error", %{} do
      assert {:error, "Invalid invite code."} = InviteCodes.validate_code("")
    end
  end

  describe "use invite code" do
    test "increments use_count on success", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id, max_uses: 3)
      {:ok, updated} = InviteCodes.use_code(code.code)
      assert updated.use_count == 1
    end

    test "returns error when code is invalid", %{} do
      assert {:error, _} = InviteCodes.use_code("nope")
    end
  end

  describe "list invite codes" do
    test "returns all codes ordered by creation", %{gm: gm} do
      {:ok, c1} = InviteCodes.create_code(gm.id)
      {:ok, c2} = InviteCodes.create_code(gm.id)

      codes = InviteCodes.list_codes()
      assert length(codes) >= 2
      ids = Enum.map(codes, & &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end
  end

  describe "deactivate code" do
    test "sets active to false", %{gm: gm} do
      {:ok, code} = InviteCodes.create_code(gm.id)
      {:ok, updated} = InviteCodes.deactivate_code(code)
      refute updated.active
    end
  end
end
