#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_destination="${1:-$project_dir/../PinBar.app}"
mkdir -p "$build_destination/Contents/MacOS" "$build_destination/Contents/Resources"
/usr/bin/swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 "$project_dir"/Sources/*.swift -o "$build_destination/Contents/MacOS/PinBar" -framework Cocoa -framework SwiftUI -framework ApplicationServices -framework ServiceManagement
cp "$project_dir/Info.plist" "$build_destination/Contents/Info.plist"
if [[ -f "$project_dir/PinBar.icns" ]]; then cp "$project_dir/PinBar.icns" "$build_destination/Contents/Resources/PinBar.icns"; fi
local_signing_state="${PINBAR_SIGNING_STATE_PATH:-$project_dir/../../work/pinbar-signing/state.json}"
if [[ -f "$local_signing_state" ]]; then
    /usr/bin/python3 "$project_dir/sign.py" "$local_signing_state" "$build_destination"
else
    /usr/bin/codesign --force --deep --sign - "$build_destination"
fi
