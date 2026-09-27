#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/.build-xcode"
release_dir="$PWD/dist"
mkdir -p "$release_dir"
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk -configuration Release -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build
stage_dir="$(mktemp -d)"
ditto --norsrc "$build_dir/Build/Products/Release/ArchiveDesk.app" "$stage_dir/ArchiveDesk.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname ArchiveDesk -srcfolder "$stage_dir" -ov -format UDZO "$release_dir/ArchiveDesk-0.5.1-universal.dmg"
ditto -c -k --norsrc --keepParent "$stage_dir/ArchiveDesk.app" "$release_dir/ArchiveDesk-0.5.1-universal.zip"
shasum -a 256 "$release_dir/ArchiveDesk-0.5.1-universal.dmg" "$release_dir/ArchiveDesk-0.5.1-universal.zip"
printf 'Staging directory retained at: %s\n' "$stage_dir"
