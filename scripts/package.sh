#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/.build-xcode"
release_dir="$PWD/dist"
version="$(tr -d '\n\r' < release-version.txt)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]
mkdir -p "$release_dir"
xcodebuild -project ArchiveDesk.xcodeproj -scheme ArchiveDesk -configuration Release -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
stage_dir="$(mktemp -d)"
ditto --norsrc "$build_dir/Build/Products/Release/ArchiveDesk.app" "$stage_dir/ArchiveDesk.app"
ln -s /Applications "$stage_dir/Applications"
lipo "$stage_dir/ArchiveDesk.app/Contents/MacOS/ArchiveDesk" -verify_arch arm64 x86_64
lipo "$stage_dir/ArchiveDesk.app/Contents/Resources/Tools/7zz" -verify_arch arm64 x86_64
lipo "$stage_dir/ArchiveDesk.app/Contents/Resources/Tools/ArchiveDeskZIP" -verify_arch arm64 x86_64
test -s "$stage_dir/ArchiveDesk.app/Contents/Resources/AppIcon.icns"
hdiutil create -volname ArchiveDesk -srcfolder "$stage_dir" -ov -format UDZO "$release_dir/ArchiveDesk-${version}-universal.dmg"
ditto -c -k --norsrc --keepParent "$stage_dir/ArchiveDesk.app" "$release_dir/ArchiveDesk-${version}-universal.zip"
shasum -a 256 "$release_dir/ArchiveDesk-${version}-universal.dmg" "$release_dir/ArchiveDesk-${version}-universal.zip"
printf 'Staging directory retained at: %s\n' "$stage_dir"
