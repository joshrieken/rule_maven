ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(RuleMaven.Repo, :manual)

# --- Wallaby browser paths (platform-dependent) ---
arch_str = fn ->
  case :erlang.system_info(:system_architecture) |> List.to_string() do
    "aarch64" <> _ -> "arm64"
    "arm64" <> _ -> "arm64"
    _ -> "x64"
  end
end

{os, arch} =
  case :os.type() do
    {:unix, :darwin} -> {"mac", arch_str.()}
    {:unix, :linux} -> {"linux", arch_str.()}
    _ -> raise "Unsupported OS for Wallaby E2E tests"
  end

browser_dir = Path.expand("../priv/browser", __DIR__)
platform = "#{os}-#{arch}"

# Worktrees don't get the chrome/chromedriver bundles: priv/browser can't be
# whole-dir symlinked (tracked install.sh makes it non-empty) and the
# CwdChanged/SessionStart setup hook never fires for subagent-created
# worktrees. Fall back to the main checkout's bundles in that case.
browser_dir =
  with false <- File.exists?(Path.join(browser_dir, "chrome-#{platform}")),
       {git_common, 0} <- System.cmd("git", ["rev-parse", "--git-common-dir"]),
       main_root = git_common |> String.trim() |> Path.expand() |> Path.dirname(),
       main_browser = Path.join(main_root, "priv/browser"),
       true <- File.exists?(Path.join(main_browser, "chrome-#{platform}")) do
    main_browser
  else
    _ -> browser_dir
  end
chrome_dir = Path.join(browser_dir, "chrome-#{platform}")
driver_bin = Path.join([browser_dir, "chromedriver-#{platform}", "chromedriver"])

chrome_bin =
  if os == "mac" do
    Path.join([
      chrome_dir,
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing"
    ])
  else
    Path.join(chrome_dir, "chrome")
  end

# Reap orphaned Chrome-for-Testing processes from prior interrupted runs.
# An abrupt BEAM exit kills chromedriver, but its Chrome children get
# reparented to PID 1 and accumulate. Only PPID-1 processes are killed,
# so a concurrently running suite (live chromedriver parent) is untouched.
with {ps_out, 0} <- System.cmd("ps", ["-axo", "pid=,ppid=,command="]) do
  for line <- String.split(ps_out, "\n", trim: true),
      [_, pid, "1", cmd] <- [Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.*)$/, line)],
      String.contains?(cmd, chrome_dir) do
    System.cmd("kill", [pid])
  end
end

unless File.exists?(chrome_bin) and File.exists?(driver_bin) do
  IO.puts(
    :stderr,
    "wallaby disabled: Chrome for Testing not found under #{browser_dir} — " <>
      "feature tests will fail. Run priv/browser/install.sh (or re-run the " <>
      "worktree setup hook) to install/symlink the browser bundles."
  )
end

if File.exists?(chrome_bin) and File.exists?(driver_bin) do
  Application.put_env(:wallaby, :chromedriver,
    headless: true,
    binary: chrome_bin,
    path: driver_bin
  )

  # Wallaby OTP app must be running for Chromedrivers supervisor
  {:ok, _} = Application.ensure_all_started(:wallaby)

  # Start RuleMaven app so endpoint serves on port 4003.
  # config/test.exs has server: true, port: 4003.
  {:ok, _} = Application.ensure_all_started(:rule_maven)
end
