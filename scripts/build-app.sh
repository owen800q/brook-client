#!/bin/sh
# Builds "build/Brook Client.app" (release, arm64/x86_64 host arch) with brook, tun2socks and the helper bundled.
#   scripts/build-app.sh            # build
#   scripts/build-app.sh --install  # build and copy to ~/Applications
set -eu
cd "$(dirname "$0")/.."

TUN2SOCKS_VERSION=v2.7.0
ARCH=$(uname -m)
case $ARCH in arm64) T2S_ASSET=tun2socks-darwin-arm64 ;; x86_64) T2S_ASSET=tun2socks-darwin-amd64 ;; *) echo "unsupported arch $ARCH" >&2; exit 1 ;; esac

# --- dependencies -----------------------------------------------------------
BROOK=$(command -v brook || true)
[ -n "$BROOK" ] || { echo "brook not found: brew install brook" >&2; exit 1; }

mkdir -p vendor
if [ ! -x vendor/tun2socks ]; then
	echo "Downloading tun2socks $TUN2SOCKS_VERSION…"
	tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/t.zip" "https://github.com/xjasonlyu/tun2socks/releases/download/$TUN2SOCKS_VERSION/$T2S_ASSET.zip"
	unzip -q -o "$tmp/t.zip" -d "$tmp"
	install -m 755 "$tmp/$T2S_ASSET" vendor/tun2socks
	rm -rf "$tmp"
fi

# --- build ------------------------------------------------------------------
swift build -c release
BIN=$(swift build -c release --show-bin-path)/BrookClient

APP="build/Brook Client.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN" "$APP/Contents/MacOS/BrookClient"
install -m 755 "$BROOK" "$APP/Contents/Resources/brook"
install -m 755 vendor/tun2socks "$APP/Contents/Resources/tun2socks"
install -m 755 helper/brook-client-helper "$APP/Contents/Resources/brook-client-helper"
install -m 755 helper/install-helper.sh "$APP/Contents/Resources/install-helper.sh"

VERSION=$(date +%Y.%m.%d)
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BrookClient</string>
	<key>CFBundleIdentifier</key><string>com.brookclient.app</string>
	<key>CFBundleName</key><string>Brook Client</string>
	<key>CFBundleDisplayName</key><string>Brook Client</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/Resources/brook" "$APP/Contents/Resources/tun2socks"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = --install ]; then
	mkdir -p "$HOME/Applications"
	rm -rf "$HOME/Applications/Brook Client.app"
	cp -R "$APP" "$HOME/Applications/"
	echo "Installed to ~/Applications/Brook Client.app"
fi
