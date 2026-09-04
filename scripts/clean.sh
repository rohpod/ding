#!/bin/bash
set -e

# Change to the project root directory
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== Cleaning ding Test State ==="

# 1. Terminate running ding process
if pgrep -x ding >/dev/null 2>&1; then
    echo "• Terminating running ding process..."
    pkill -x ding || true
    sleep 0.5
fi

# 2. Unregister macOS Login Item via ding.app bundle
if [ -d "$ROOT_DIR/.build/ding.app" ]; then
    echo "• Unregistering login item from macOS..."
    "$ROOT_DIR/.build/ding.app/Contents/MacOS/ding" --reset-login-item 2>/dev/null || true
elif [ -d "$ROOT_DIR/build/ding.app" ]; then
    echo "• Unregistering login item from macOS..."
    "$ROOT_DIR/build/ding.app/Contents/MacOS/ding" --reset-login-item 2>/dev/null || true
fi

# 3. Reset macOS Notifications and privacy permissions
echo "• Resetting macOS notification permissions..."
tccutil reset All com.ding.mac 2>/dev/null || true

# 4. Clear saved preferences from UserDefaults
echo "• Clearing com.ding.mac UserDefaults..."
defaults delete com.ding.mac 2>/dev/null || true

echo "✓ All test state removed! ding is reset to a fresh first-launch state."
