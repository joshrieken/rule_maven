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
