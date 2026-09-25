#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# A fresh Mac may have full Xcode installed while xcode-select still points at
# CommandLineTools. Respect an explicit override and avoid changing system settings.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] \
  && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
echo "Selected Xcode: $(xcode-select -p)"
xcodebuild -version
xcodebuild -showsdks
plutil -lint WatchApp/Info.plist X6Remote.xcodeproj/project.pbxproj
xcrun swift test --package-path Packages/X6Core
xcrun swift run --package-path Packages/X6Core x6-fixture-check Packages/X6Core/Tests/X6CoreTests/Fixtures/x6-v1.1.7.json
xcodebuild -project X6Remote.xcodeproj -scheme X6Remote -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath DerivedData/Simulator \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project X6Remote.xcodeproj -scheme X6Remote -configuration Debug \
  -destination 'generic/platform=watchOS' -derivedDataPath DerivedData/Device \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project X6Remote.xcodeproj -scheme X6RemotePhone -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData/PhoneSimulator \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project X6Remote.xcodeproj -scheme X6RemotePhone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData/PhoneDevice \
  CODE_SIGNING_ALLOWED=NO build
echo 'Unsigned Watch and iPhone SDK builds passed. Physical Shortcut discovery, Watch BLE, signing, haptics and background tests are still required.'
