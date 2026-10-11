#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/spikes/starship-sim-build/Release-iphonesimulator/Starship.app"
BUNDLE_ID="com.harbourmasters.starship"
SF64="$ROOT/oracle/shiphome/sf64.o2r"
SHOT="${1:-sim-boot}"
SIM_NAME="${STARSHIP_SIM_NAME:-iPhone Air}"
UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; n=sys.argv[1]; d=json.load(sys.stdin)['devices']; print(next(x['udid'] for k,v in d.items() if 'iOS-27-0' in k for x in v if x['name']==n))" "$SIM_NAME")
[[ -n "$UDID" ]] || { echo "FATAL: no available '$SIM_NAME' on iOS 27.0 (ask the user; never simctl create)" >&2; exit 1; }

[[ -d "$APP" ]] || { echo "FATAL: no sim app at $APP — run scripts/build-sim.sh" >&2; exit 1; }

xcrun simctl bootstatus "$UDID" -b   # boots if needed, waits until ready
xcrun simctl install "$UDID" "$APP"

CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
if [[ "${2:-}" != "--no-seed" ]]; then
    [[ -f "$SF64" ]] || { echo "FATAL: no sf64.o2r — run scripts/extract-sf64-o2r.sh" >&2; exit 1; }
    mkdir -p "$CONTAINER/Documents"
    cp "$SF64" "$CONTAINER/Documents/sf64.o2r"
    echo "seeded sf64.o2r into $CONTAINER/Documents"
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
echo "launched $BUNDLE_ID on sim; waiting for boot (first launch compiles shaders)…"

for _ in $(seq 1 12); do
    xcrun simctl spawn "$UDID" log show --last 30s 2>/dev/null | grep -qE "Starship|SohIosShell" && break
    sleep 5
done

mkdir -p "$ROOT/artifacts"
xcrun simctl io "$UDID" screenshot "$ROOT/artifacts/$SHOT.png"
echo "captured artifacts/$SHOT.png"
sips -g pixelWidth -g pixelHeight "$ROOT/artifacts/$SHOT.png" 2>/dev/null | tail -2 || true

LOGDIR="$CONTAINER/Documents/logs"
if [[ -d "$LOGDIR" ]]; then
    cp -R "$LOGDIR" "$ROOT/artifacts/$SHOT-logs"
    echo "--- SOH_PERF (simulator, non-authoritative) ---"
    grep -h "SOH_PERF" "$ROOT/artifacts/$SHOT-logs"/* 2>/dev/null | tail -3 || echo "(no perf lines yet)"
fi
