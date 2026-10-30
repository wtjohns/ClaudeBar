#!/bin/sh
# Builds a Release ClaudeBar.app, ad-hoc signs the whole bundle, and packages a DMG.
#
# A complete ad-hoc signature matters: Xcode's CODE_SIGNING_ALLOWED=NO build leaves only
# the linker's signature on the binary with no sealed resources, which macOS reports as
# "damaged and can't be opened" with no way past it. A fully signed bundle instead gets
# the normal "unverified developer" prompt, which users can approve in
# System Settings → Privacy & Security → Open Anyway.
#
# Usage: scripts/release.sh   → release/ClaudeBar-<version>.dmg
set -eu

cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ClaudeBar/Info.plist)
APP=build/DerivedData/Build/Products/Release/ClaudeBar.app
DMG=release/ClaudeBar-$VERSION.dmg

xcodebuild -project ClaudeBar.xcodeproj -scheme ClaudeBar -configuration Release \
    -derivedDataPath build/DerivedData \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    -quiet build

codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ClaudeBar.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p release
rm -f "$DMG"
hdiutil create -volname "ClaudeBar $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
echo "$DMG"
