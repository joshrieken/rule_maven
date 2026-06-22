#!/bin/bash
# Download Chrome for Testing + ChromeDriver to priv/browser/
# Uses the Chrome for Testing JSON API to get the latest stable version.
set -euo pipefail

BROWSER_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Detect platform ---
case "$(uname -s)" in
  Darwin)
    OS="mac"
    ;;
  Linux)
    OS="linux"
    ;;
  *)
    echo "ERROR: unsupported OS: $(uname -s)"
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64)        ARCH="x64" ;;
  *)
    echo "ERROR: unsupported arch: $(uname -m)"
    exit 1
    ;;
esac

PLATFORM="$OS-$ARCH"

# Zip extracts to chrome-{platform}/ and chromedriver-{platform}/
CHROME_DIR="$BROWSER_DIR/chrome-$PLATFORM"
DRIVER_BIN="$BROWSER_DIR/chromedriver-$PLATFORM/chromedriver"

# macOS chrome binary is inside the .app bundle
if [ "$OS" = "mac" ]; then
  CHROME_BIN="$CHROME_DIR/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
else
  CHROME_BIN="$CHROME_DIR/chrome"
fi

# --- If already installed, skip ---
if [ -f "$CHROME_BIN" ] && [ -f "$DRIVER_BIN" ]; then
  echo "Chrome and ChromeDriver already installed in $BROWSER_DIR"
  echo "  chrome:      $CHROME_BIN"
  echo "  chromedriver: $DRIVER_BIN"
  exit 0
fi

# --- Fetch latest stable version ---
echo "Fetching latest Chrome for Testing version..."
VERSION_JSON_URL="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json"
VERSION=$(curl -fsSL "$VERSION_JSON_URL" 2>/dev/null | grep -o '"Stable","version":"[^"]*"' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)

if [ -z "$VERSION" ]; then
  echo "ERROR: could not determine latest Chrome version from $VERSION_JSON_URL"
  echo "Try setting CHROME_VERSION manually: CHROME_VERSION=131.0.6778.85 bash $0"
  exit 1
fi

echo "Latest stable: $VERSION"

# --- Download Chrome ---
CHROME_URL="https://storage.googleapis.com/chrome-for-testing-public/$VERSION/$PLATFORM/chrome-$PLATFORM.zip"
echo "Downloading Chrome from $CHROME_URL ..."
curl -fSL --progress-bar "$CHROME_URL" -o "$BROWSER_DIR/chrome.zip"
echo "Extracting Chrome..."
unzip -qo "$BROWSER_DIR/chrome.zip" -d "$BROWSER_DIR/"
rm "$BROWSER_DIR/chrome.zip"

# --- Download ChromeDriver ---
DRIVER_URL="https://storage.googleapis.com/chrome-for-testing-public/$VERSION/$PLATFORM/chromedriver-$PLATFORM.zip"
echo "Downloading ChromeDriver from $DRIVER_URL ..."
curl -fSL --progress-bar "$DRIVER_URL" -o "$BROWSER_DIR/chromedriver.zip"
echo "Extracting ChromeDriver..."
unzip -qo "$BROWSER_DIR/chromedriver.zip" -d "$BROWSER_DIR/"
rm "$BROWSER_DIR/chromedriver.zip"

# --- Make driver executable ---
chmod +x "$DRIVER_BIN"

# --- Verify ---
if [ -f "$CHROME_BIN" ] && [ -f "$DRIVER_BIN" ]; then
  echo ""
  echo "Done! Chrome for Testing $VERSION installed."
  echo "  chrome:       $CHROME_BIN"
  echo "  chromedriver: $DRIVER_BIN"
else
  echo "ERROR: installation failed - binaries not found."
  echo "  expected chrome:      $CHROME_BIN"
  echo "  expected chromedriver: $DRIVER_BIN"
  exit 1
fi
