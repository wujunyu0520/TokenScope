#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="TokenScope"
BUNDLE_ID="com.jerrylee.tokenscope"
BINARY_NAME="TokenScopeApp"

strip_extended_attributes() {
    local path="$1"
    if command -v xattr >/dev/null 2>&1; then
        local item
        xattr -cr "$path"
        while IFS= read -r -d '' item; do
            xattr -d com.apple.FinderInfo "$item"
        done < <(find "$path" -xattrname com.apple.FinderInfo -print0)
        while IFS= read -r -d '' item; do
            xattr -d 'com.apple.fileprovider.fpfs#P' "$item"
        done < <(find "$path" -xattrname 'com.apple.fileprovider.fpfs#P' -print0)
    fi
}

verify_strict_codesign() {
    local path="$1"
    local attempt
    for attempt in {1..20}; do
        strip_extended_attributes "$path"
        if codesign --verify --deep --strict --verbose=2 "$path" >/dev/null 2>&1; then
            strip_extended_attributes "$path"
            return 0
        fi
        sleep 0.25
    done

    strip_extended_attributes "$path"
    codesign --verify --deep --strict --verbose=2 "$path" >/dev/null
}

cd "$ROOT"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BUILT_BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BINARY_NAME"
if [ ! -x "$BUILT_BIN" ]; then
    echo "Binary not found at $BUILT_BIN" >&2
    exit 1
fi

APP_DIR="$ROOT/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILT_BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

RESOURCE_DIR="$(dirname "$BUILT_BIN")"
for RESOURCE_BUNDLE in "$RESOURCE_DIR"/TokenScope_*.bundle; do
    if [ -d "$RESOURCE_BUNDLE" ]; then
        cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
    fi
done

# Generate icon if missing, then copy into bundle
ICON_SRC="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] && [ -f "$ROOT/Scripts/generate_icon.swift" ]; then
    echo "==> generating AppIcon.icns"
    (cd "$ROOT" && swift Scripts/generate_icon.swift >/dev/null)
    iconutil -c icns -o "$ICON_SRC" "$ROOT/build/AppIcon.iconset"
fi
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUM="${APP_BUILD:-1}"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<'PKG'
APPL????
PKG

if [ "${CODEXBAR_SIGNING:-adhoc}" = "adhoc" ]; then
    strip_extended_attributes "$APP_DIR"
    echo "==> codesign (ad-hoc)"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
    verify_strict_codesign "$APP_DIR"
fi

echo "==> Built $APP_DIR"
