#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/spikes/starship-sim-build"
PREFIX="$ROOT/work/ios-sim-deps/prefix"
SHIP_O2R="$ROOT/oracle/build-cmake/starship.o2r"

[[ -d "$ROOT/vendor/Starship/.git" ]] || "$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/apply-overlay.sh"
[[ -f "$PREFIX/lib/libvorbisfile.a" ]] || SOH_IOS_SDK=simulator "$ROOT/scripts/build-audio-deps-ios.sh"
[[ -f "$SHIP_O2R" ]] || "$ROOT/scripts/build-oracle.sh"

export CMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --no-warn-unused-cli -S "$ROOT/vendor/Starship" -B "$BUILD" -GXcode \
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
    -DCMAKE_SYSTEM_NAME=iOS -DPLATFORM=SIMULATORARM64 \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DDEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
    -DBUNDLE_ID=com.harbourmasters.starship \
    "-DSOH_IOS_DEPS_PREFIX=$PREFIX" \
    "-DSOH_O2R_PATH=$SHIP_O2R" \
    "-DSOH_IOS_SHELL_DIR=$ROOT/app/ios" \
    "-DSOH_REMOTE_CONSOLE=${SOH_IOS_CONSOLE:-1}" \
    `# D-040: sim is dev-only -> console/bridge ON by default (needed for the test harness)` \
    "-DSOH_IOS_MENU_DIR=$ROOT/app/menu"

cmake --build "$BUILD" --config Release --target Starship --parallel 6

APP="$BUILD/Release-iphonesimulator/Starship.app"
[[ -d "$APP" ]] || { echo "FATAL: expected app at $APP" >&2; exit 1; }
lipo -info "$APP/Starship"
SDLMAIN_COUNT=$(nm "$APP/Starship" | grep -c " T _SDL_main\| t _SDL_main" || true)
[[ "$SDLMAIN_COUNT" -ge 1 ]] || {
    echo "FATAL: no SDL_main symbol — game entry bypasses SDL2main's UIKit shim" >&2; exit 1; }
echo "built (simulator): $APP"
