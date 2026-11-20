defmodule RuleMaven.ChangelogTest do
  use RuleMaven.DataCase, async: true

  alias Lccz.Changelog.Release
  alias RuleMaven.{Changelog, Users}

  @sample """
  # Changelog

  Intro text, with a - dash that is not a bullet.

  ## Unreleased
  ### Everyone
  - Not released yet.

  ## v0.2.0 (2026-12-01)
  ### Everyone
  - Short one.
  - A long bullet that wraps
    onto a second line
    and a third.
  ### Admins
  - Admin only.

  ## v0.1.1 (2026-11-20)
  ### Admins
  - Only for admins.

  ## v0.1.0 — 2026-11-15
  ### Everyone
  * Old heading style still parses.
  ### Mystery
  - Unknown sections are dropped.
  """

  defp create_user!(name, role \\ "user") do
    {:ok, user} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  describe "app_version/0" do
    test "is the VERSION file, and the newest CHANGELOG entry is that release" do
      version = "VERSION" |> File.read!() |> String.trim()
      assert Changelog.app_version() == version
      # A "Release vX.Y.Z" commit bumps VERSION and adds its entry together.
      assert [%{version: ^version} | _] = Changelog.releases()
    end
  end

  describe "parse/1" do
    test "reads releases newest first with sections, dates and multi-line bullets" do
      assert [
               %Release{
                 version: "0.2.0",
                 date: ~D[2026-12-01],
                 everyone: [
                   "Short one.",
                   "A long bullet that wraps onto a second line and a third."
                 ],
                 admins: ["Admin only."]
               },
               %Release{version: "0.1.1", everyone: [], admins: ["Only for admins."]},
               %Release{
                 version: "0.1.0",
                 date: ~D[2026-11-15],
                 everyone: ["Old heading style still parses."],
                 admins: []
               }
             ] = Changelog.parse(@sample)
    end

    test "skips Unreleased and bullets outside a known section" do
      releases = Changelog.parse(@sample)
      all_items = Enum.flat_map(releases, &(&1.everyone ++ &1.admins))
      refute "Not released yet." in all_items
      refute "Unknown sections are dropped." in all_items
    end

    test "is lenient: empty, junk and dateless input" do
      assert Changelog.parse("") == []
      assert Changelog.parse("no headings here\n- a stray bullet") == []

      assert [%Release{version: "1.0.0", date: nil, everyone: ["x"]}] =
               Changelog.parse("## 1.0.0\n### everyone\n- x\n")
    end

    test "the real CHANGELOG.md parses into at least one release" do
      assert [%Release{} | _] = Changelog.releases()
      assert Enum.all?(Changelog.releases(), &Regex.match?(~r/^\d+\.\d+\.\d+$/, &1.version))
    end
  end

  describe "reader filtering" do
    setup do: %{all: Changelog.parse(@sample)}

    test "non-admins never get admins' notes", %{all: all} do
      assert Enum.all?(Changelog.reader_releases(false, all), &(&1.admins == []))
      assert ["Admin only."] = hd(Changelog.reader_releases(true, all)).admins
    end

    test "visible releases drop the admin-only release for non-admins", %{all: all} do
      assert Enum.map(Changelog.visible_releases(false, all), & &1.version) == ["0.2.0", "0.1.0"]

      assert Enum.map(Changelog.visible_releases(true, all), & &1.version) ==
               ["0.2.0", "0.1.1", "0.1.0"]
    end
  end

  describe "unseen?/3" do
    test "true until the newest release with notes for this reader is the seen one" do
      all = Changelog.parse(@sample)
      assert Changelog.unseen?(false, nil, all)
      assert Changelog.unseen?(false, "0.1.0", all)
      refute Changelog.unseen?(false, "0.2.0", all)
    end

    test "admins count Admins notes; others don't" do
      all =
        Changelog.parse("""
        ## v0.3.0 (2026-12-05)
        ### Admins
        - Admin only.
        ## v0.2.0 (2026-12-01)
        ### Everyone
        - For all.
        """)

      refute Changelog.unseen?(false, "0.2.0", all)
      assert Changelog.unseen?(true, "0.2.0", all)
      refute Changelog.unseen?(true, "0.3.0", all)
    end

    test "no releases means nothing unseen" do
      refute Changelog.unseen?(true, nil, [])
    end
  end

  describe "unseen_for?/2 and mark_seen/2" do
    setup do: %{all: Changelog.parse(@sample)}

    test "signed-out visitors never have news", %{all: all} do
      refute Changelog.unseen_for?(nil, all)
      assert {:ok, nil} = Changelog.mark_seen(nil, all)
    end

    test "marking seen stores the newest visible version and clears the mark", %{all: all} do
      user = create_user!("cl_reader")
      assert Changelog.unseen_for?(user, all)

      assert {:ok, user} = Changelog.mark_seen(user, all)
      assert user.seen_version == "0.2.0"
      assert Users.get_user(user.id).seen_version == "0.2.0"
      refute Changelog.unseen_for?(user, all)
    end

    test "an admin's mark goes by releases with admins' notes too" do
      all = Changelog.parse("## v0.3.0\n### Admins\n- a\n## v0.2.0\n### Everyone\n- e\n")
      admin = create_user!("cl_admin", "admin")
      user = create_user!("cl_plain")

      assert {:ok, %{seen_version: "0.3.0"}} = Changelog.mark_seen(admin, all)
      assert {:ok, %{seen_version: "0.2.0"}} = Changelog.mark_seen(user, all)
    end
  end
end
