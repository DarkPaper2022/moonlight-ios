#!/bin/bash
set -euo pipefail
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/moonlight-direction-ui.XXXXXX")
simulator_id=""
cleanup() {
    if [[ -n "$simulator_id" ]]; then
        xcrun simctl shutdown "$simulator_id" || true
        xcrun simctl delete "$simulator_id" || true
    fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
runtime_id=$(xcrun simctl list runtimes available -j | python3 -c 'import json,sys; print(next(x["identifier"] for x in json.load(sys.stdin)["runtimes"] if ".iOS-" in x["identifier"]))')
device_type=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; print(next(x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"] == "iPhone 16 Pro"))')
simulator_id=$(xcrun simctl create MoonlightDirectionTest "$device_type" "$runtime_id")
[[ "$simulator_id" =~ ^[0-9A-Fa-f-]{36}$ ]]
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
mkdir -p "$test_dir/DirectionTest.app"
python3 - "$test_dir/DirectionTest.app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable='DirectionTest', CFBundleIdentifier='io.darkpaper.moonlight.direction-test', CFBundleName='DirectionTest', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='15.0', LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2]), f)
PY
xcrun --sdk iphonesimulator clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -target "$(uname -m)-apple-ios15.0-simulator" \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    tests/test_directional_key_control.m Limelight/Input/DirectionalKeyControl.m \
    -framework UIKit -framework Foundation -framework QuartzCore \
    -o "$test_dir/DirectionTest.app/DirectionTest"
codesign --force --sign - "$test_dir/DirectionTest.app"
xcrun simctl install "$simulator_id" "$test_dir/DirectionTest.app"
xcrun simctl launch "$simulator_id" io.darkpaper.moonlight.direction-test
container_path=$(xcrun simctl get_app_container "$simulator_id" io.darkpaper.moonlight.direction-test data)
for attempt in {1..30}; do
    if [[ -f "$container_path/Documents/directional-result.txt" ]]; then
        cat "$container_path/Documents/directional-result.txt"
        exit 0
    fi
    sleep 1
done
echo "UIKit direction-control checks did not complete" >&2
exit 1
