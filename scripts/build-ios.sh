#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-ios"
PREFIX="$ROOT/work/ios-deps/prefix"
SHIP_O2R="$ROOT/oracle/build-cmake/starship.o2r"
TEAM="${SOH_IOS_TEAM:?set your Apple Developer team id (see README)}"

[[ -d "$ROOT/vendor/Starship/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libvorbisfile.a" ]] || "$ROOT/scripts/build-audio-deps-ios.sh"
if [[ ! -f "$SHIP_O2R" ]]; then
    echo "starship.o2r missing — building host oracle first (produces it)"
    "$ROOT/scripts/build-oracle.sh"
fi

rm -rf "$BUILD/Release-iphoneos/Starship.app" "$BUILD/Starship.xcarchive" "$BUILD/export"

export CMAKE_POLICY_VERSION_MINIMUM=3.5

SOH_IOS_BUNDLE_VERSION=$(awk -F. '{print (NF>=4)?$4+1:1}' "$ROOT/VERSION" 2>/dev/null || echo 1)

cmake --no-warn-unused-cli -S "$ROOT/vendor/Starship" -B "$BUILD" -GXcode \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DDEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DBUNDLE_ID=com.rebelancap.starship \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SHIP_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    "-DSOH_IOS_BUNDLE_VERSION=$SOH_IOS_BUNDLE_VERSION" \
    "-DSOH_REMOTE_CONSOLE=${SOH_IOS_CONSOLE:-0}" \
    `# D-040: console/bridge OFF by default (public release safe); OTA/dev: SOH_IOS_CONSOLE=1` \
    "-DSOH_IOS_MENU_DIR=$ROOT/app/menu" \
    -DSOH_IOS_BUNDLE_IDENTIFIER=com.rebelancap.starship \
    "-DSOH_IOS_DEVELOPMENT_TEAM=$TEAM"

cmake --build "$BUILD" --config Release --target Starship --parallel 6 -- -allowProvisioningUpdates

APP="$BUILD/Release-iphoneos/Starship.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | sed -n '1,3p'
SDLMAIN_COUNT=$(nm "$APP/Starship" | grep -c " T _SDL_main\| t _SDL_main" || true)
[[ "$SDLMAIN_COUNT" -ge 1 ]] || {
    echo "FATAL: no SDL_main symbol — game entry bypasses SDL2main's UIKit shim" >&2; exit 1; }
echo "built: $APP"
