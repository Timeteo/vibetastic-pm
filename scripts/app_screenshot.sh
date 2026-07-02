#!/bin/bash
# R2 gate helper — N cold launches + screenshots on an iOS simulator (see VERIFY.md, R2 rules).
# A single screenshot is not a valid pass for a launch-timing race: this launches the app
# cold N times and captures one screenshot per launch; the orchestrator inspects all N and
# passes only if the defect never appears.
#
# Usage:
#   bash scripts/app_screenshot.sh <bundle-id> [launches] [settle-seconds] [out-dir] [device]
#
#   bundle-id       e.g. com.example.MyApp (app must already be installed on the sim)
#   launches        cold launch count (default 5; use 1 for a plain presence check)
#   settle-seconds  wait after launch before the screenshot (default 4)
#   out-dir         screenshot destination (default artifacts/r2)
#   device          simctl device (default "booted")
#
# Exits non-zero if any launch or capture fails. Deciding pass/fail on the *content* of the
# screenshots is the orchestrator's job, not this script's.
set -euo pipefail

BUNDLE_ID="${1:?usage: app_screenshot.sh <bundle-id> [launches] [settle-seconds] [out-dir] [device]}"
LAUNCHES="${2:-5}"
SETTLE="${3:-4}"
OUT_DIR="${4:-artifacts/r2}"
DEVICE="${5:-booted}"

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

for i in $(seq 1 "$LAUNCHES"); do
  # Cold start: make sure the app is dead before launching.
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
  sleep "$SETTLE"
  SHOT="$OUT_DIR/${BUNDLE_ID##*.}-${STAMP}-launch${i}.png"
  xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null
  echo "$SHOT"
done

echo "[app_screenshot] $LAUNCHES cold launch(es) captured to $OUT_DIR — inspect ALL frames (VERIFY.md R2)." >&2
