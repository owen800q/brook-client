#!/bin/sh
# Builds a universal (arm64 + x86_64) "build/Brook Client.app" with brook, tun2socks and the helper bundled.
#   scripts/build-app.sh            # build
#   scripts/build-app.sh --install  # build and copy to ~/Applications
#   scripts/build-app.sh --release  # build and package build/BrookClient-<version>-macOS-universal.{zip,dmg}
# VERSION=1.2.3 overrides the version (default: today's date).
set -eu
cd "$(dirname "$0")/.."

BROOK_VERSION=v20270101
TUN2SOCKS_VERSION=v2.7.0
VERSION=${VERSION:-$(date +%Y.%m.%d)}

# --- dependencies (official release binaries for both architectures, lipo'd) --
fetch() { # url dest
	[ -s "$2" ] || { echo "Downloading $1"; curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"; }
}
mkdir -p vendor/dl
fetch "https://github.com/txthinking/brook/releases/download/$BROOK_VERSION/brook_darwin_arm64" vendor/dl/brook-arm64
fetch "https://github.com/txthinking/brook/releases/download/$BROOK_VERSION/brook_darwin_amd64" vendor/dl/brook-x86_64
for a in arm64:arm64 amd64:x86_64; do
	asset=tun2socks-darwin-${a%%:*}
	zip=vendor/dl/$asset.zip
	fetch "https://github.com/xjasonlyu/tun2socks/releases/download/$TUN2SOCKS_VERSION/$asset.zip" "$zip"
	[ -s "vendor/dl/tun2socks-${a##*:}" ] || { unzip -q -o "$zip" "$asset" -d vendor/dl && mv "vendor/dl/$asset" "vendor/dl/tun2socks-${a##*:}"; }
done
lipo -create vendor/dl/brook-arm64 vendor/dl/brook-x86_64 -output vendor/brook
lipo -create vendor/dl/tun2socks-arm64 vendor/dl/tun2socks-x86_64 -output vendor/tun2socks
chmod 755 vendor/brook vendor/tun2socks

# --- build ------------------------------------------------------------------
bins=
for arch in arm64 x86_64; do
	swift build -c release --triple "$arch-apple-macosx12.0"
	bins="$bins $(swift build -c release --triple "$arch-apple-macosx12.0" --show-bin-path)/BrookClient"
done

APP="build/Brook Client.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2086
lipo -create $bins -output "$APP/Contents/MacOS/BrookClient"
install -m 755 vendor/brook "$APP/Contents/Resources/brook"
install -m 755 vendor/tun2socks "$APP/Contents/Resources/tun2socks"
install -m 755 helper/brook-client-helper "$APP/Contents/Resources/brook-client-helper"
install -m 755 helper/install-helper.sh "$APP/Contents/Resources/install-helper.sh"
install -m 644 assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BrookClient</string>
	<key>CFBundleIdentifier</key><string>com.brookclient.app</string>
	<key>CFBundleName</key><string>Brook Client</string>
	<key>CFBundleDisplayName</key><string>Brook Client</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/brook" "$APP/Contents/Resources/tun2socks"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/BrookClient"))"

case ${1:-} in
--install)
	mkdir -p "$HOME/Applications"
	rm -rf "$HOME/Applications/Brook Client.app"
	cp -R "$APP" "$HOME/Applications/"
	echo "Installed to ~/Applications/Brook Client.app"
	;;
--release)
	base=build/BrookClient-$VERSION-macOS-universal
	rm -f "$base.zip" "$base.dmg"
	ditto -c -k --keepParent "$APP" "$base.zip"
	stage=$(mktemp -d)
	cp -R "$APP" "$stage/"
	ln -s /Applications "$stage/Applications"
	hdiutil create -quiet -volname "Brook Client" -srcfolder "$stage" -format UDZO "$base.dmg"
	rm -rf "$stage"
	(cd build && shasum -a 256 "$(basename "$base").zip" "$(basename "$base").dmg" >"$(basename "$base").sha256")
	echo "Packaged $base.zip $base.dmg"
	;;
esac
