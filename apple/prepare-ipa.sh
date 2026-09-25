#!/bin/bash
# Test, then build the iPhone app with its embedded Watch app as an unsigned IPA.
# Sign and install it yourself (Xcode, or a sideloading tool of your choice).
set -euo pipefail
cd "$(dirname "$0")"
repo_dir="$(cd .. && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Run this script on a Mac with full Xcode and the iOS/watchOS SDKs.' >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] \
  && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 1; }
out_dir="$repo_dir/build/ipa"
work_dir="$(mktemp -d)"
mkdir -p "$out_dir"
xcodebuild -version
plutil -lint WatchApp/Info.plist X6Remote.xcodeproj/project.pbxproj
xcrun swift test --package-path Packages/X6Core
xcrun swift run --package-path Packages/X6Core x6-fixture-check \
  Packages/X6Core/Tests/X6CoreTests/Fixtures/x6-v1.1.7.json
# The phone scheme embeds the Watch target. Signing is disabled for both.
for platform in 'iOS Simulator' 'iOS'; do
  xcodebuild -project X6Remote.xcodeproj -scheme X6RemotePhone \
    -configuration Debug -destination "generic/platform=$platform" \
    -derivedDataPath "$work_dir/DerivedData-${platform// /}" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
done
phone_app="$work_dir/DerivedData-iOS/Build/Products/Debug-iphoneos/X6RemotePhone.app"
[[ -f "$phone_app/Watch/X6Remote.app/Info.plist" ]] || {
  echo 'Embedded Watch app missing from the phone app.' >&2; exit 1;
}
mkdir -p "$work_dir/package/Payload"
cp -R "$phone_app" "$work_dir/package/Payload/"
# Exclude AppleDouble sidecars (._*.app), which break installation.
(cd "$work_dir/package" && /usr/bin/ditto -c -k --norsrc --noextattr --noqtn \
  --keepParent Payload "$out_dir/X6Remote-unsigned.ipa")
python3 - "$repo_dir" "$out_dir" <<'PY'
import hashlib, json, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
repo, output = map(Path, sys.argv[1:])
ipa = output / 'X6Remote-unsigned.ipa'
commit = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
dirty = bool(subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip())
manifest = dict(source_commit=commit, source_has_local_changes=dirty,
                built_utc=datetime.now(timezone.utc).isoformat(),
                ipa_sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(), signing='unsigned')
(output / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
PY
echo "Unsigned IPA: $out_dir/X6Remote-unsigned.ipa"
