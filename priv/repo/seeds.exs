alias RuleMaven.Repo
alias RuleMaven.Users.User

# --- Admin User ---

username = "admin"
email = "admin@rulemaven.local"
password = "admin"

if is_nil(Repo.get_by(User, username: username)) do
  Repo.insert!(
    User.registration_changeset(%User{}, %{
      username: username,
      email: email,
      password: password,
      role: "game_master"
    })
  )

  IO.puts("Seeded game_master user: #{username} / #{password}")
else
  IO.puts("game_master user already exists: #{username}")
end

# --- Player User ---

player_username = "player"
player_email = "player@rulemaven.local"
player_password = "player"

if is_nil(Repo.get_by(User, username: player_username)) do
  Repo.insert!(
    User.registration_changeset(%User{}, %{
      username: player_username,
      email: player_email,
      password: player_password,
      role: "player"
    })
  )

  IO.puts("Seeded player user: #{player_username} / #{player_password}")
else
  IO.puts("player user already exists: #{player_username}")
end

IO.puts(
  "\nSeeds complete! Log in at http://localhost:4000/login with admin / admin or player / player"
)

IO.puts("Use BGG import to add your games.")
