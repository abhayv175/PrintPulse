#!/usr/bin/env bash
# ==============================================================================
# PrintPulse Autonomous Local Development Runner
# Auto-detects and synchronizes your Mac's active Wi-Fi LAN IP across backend & Flutter.
# ==============================================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Detect and synchronize LAN IP
python3 "$REPO_ROOT/scripts/sync_ip.py"

MODE="${1:-all}"

export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"

case "$MODE" in
  sync)
    echo "✓ Dynamic IP synchronization complete."
    ;;
  backend)
    echo "Starting Uvicorn backend on 0.0.0.0:8000..."
    cd "$REPO_ROOT/backend"
    exec .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
    ;;
  app)
    echo "Launching Flutter vendor-app on connected Android device..."
    cd "$REPO_ROOT/vendor-app"
    DEVICE=$(adb devices | grep -w "device" | head -n 1 | awk '{print $1}' || true)
    if [ -n "$DEVICE" ]; then
      exec flutter run --profile -d "$DEVICE"
    else
      echo "No physical device connected via ADB. Building APK..."
      exec flutter build apk --debug
    fi
    ;;
  all)
    echo "Checking backend status..."
    if ! nc -z 127.0.0.1 8000 2>/dev/null; then
      echo "Starting Uvicorn backend in background..."
      (cd "$REPO_ROOT/backend" && .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload) &
      sleep 2
    else
      echo "✓ Backend is already running on port 8000."
    fi
    cd "$REPO_ROOT/vendor-app"
    DEVICE=$(adb devices | grep -w "device" | head -n 1 | awk '{print $1}' || true)
    if [ -n "$DEVICE" ]; then
      exec flutter run --profile -d "$DEVICE"
    else
      echo "No device attached via ADB. Running Flutter test suite..."
      exec flutter test test/widget_test.dart
    fi
    ;;
  *)
    echo "Usage: ./dev.sh [sync|backend|app|all]"
    ;;
esac
