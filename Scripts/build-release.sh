#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="Blazing Transcribe"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/BlazingTranscribe.dmg"
EXECUTABLE_NAME="BlazingFastTranscription"
VERSION="${1:-1.0.0}"

# Code signing / notarization (optional — set via env vars)
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE_KEYCHAIN_PROFILE="${NOTARIZE_KEYCHAIN_PROFILE:-}"
ENTITLEMENTS="$PROJECT_ROOT/BlazingTranscribe.entitlements"

# Marketing/updates site lives in its OWN repo. Point SITE_DIR at your local
# checkout of it (the DMG + Sparkle appcast are written under $SITE_DIR/public).
# Defaults to a nested ./site for backward compatibility.
SITE_DIR="${SITE_DIR:-$PROJECT_ROOT/site}"

echo "==> Building $APP_NAME v$VERSION release..."

# Clean previous build artifacts
rm -rf "$APP_BUNDLE" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

# Build release binary
echo "==> swift build -c release"
cd "$PROJECT_ROOT"
swift build -c release

BINARY="$PROJECT_ROOT/.build/release/$EXECUTABLE_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Release binary not found at $BINARY"
    exit 1
fi

# Create .app bundle structure
echo "==> Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Remove dangling Xcode toolchain rpath injected by swift build
# This is the #1 cause of Gatekeeper rejections for notarized apps
# (see: https://developer.apple.com/forums/thread/706414)
DANGLING_RPATH=$(otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -A2 "LC_RPATH" | grep "Xcode" | awk '{print $2}')
if [ -n "$DANGLING_RPATH" ]; then
    echo "==> Removing dangling Xcode toolchain rpath: $DANGLING_RPATH"
    install_name_tool -delete_rpath "$DANGLING_RPATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# Bundle Sparkle.framework (linked at @rpath/Sparkle.framework)
SPARKLE_SRC="$PROJECT_ROOT/.build/release/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
    echo "==> Bundling Sparkle.framework"
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/"
    # Add Frameworks rpath so @rpath/Sparkle.framework resolves
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

# Copy app icon if it exists
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "==> App icon copied"
else
    echo "==> Warning: No AppIcon.icns found in Resources/ — app will use default icon"
fi

# Generate Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Blazing Transcribe</string>
    <key>CFBundleDisplayName</key>
    <string>Blazing Transcribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.blazingtranscribe.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>Blazing Transcribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Blazing Transcribe needs microphone access to capture and transcribe your speech in real time.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Blazing Transcribe needs accessibility access to type transcribed text directly into your active application.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://www.blazingfasttranscription.com/appcast.xml</string>
    <key>SUScheduledCheckInterval</key>
    <integer>14400</integer>
    <key>SUPublicEDKey</key>
    <string>iG13Ob4OP3zkVYGMwsJt9ttYmZA6mChEGPFAdN9RWKo=</string>
</dict>
</plist>
PLIST

echo "==> App bundle created at $APP_BUNDLE"

# Code signing (skip if no identity set)
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Code signing with identity: $SIGNING_IDENTITY"

    # Sign embedded frameworks inside-out (NO app entitlements — just runtime + timestamp)
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
        echo "==> Signing Sparkle.framework components inside-out"

        # Sign XPC services
        find "$SPARKLE_FW" -name "*.xpc" -type d | while IFS= read -r xpc; do
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$xpc"
        done

        # Sign helper apps
        find "$SPARKLE_FW" -name "*.app" -type d | while IFS= read -r app; do
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$app"
        done

        # Sign standalone executables (Autoupdate)
        find "$SPARKLE_FW/Versions/B" -maxdepth 1 -type f -perm +111 ! -name "Sparkle" | while IFS= read -r exe; do
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$exe"
        done

        # Sign the framework itself
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$SPARKLE_FW"
    fi

    # Sign any other dylibs/frameworks
    if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
        find "$APP_BUNDLE/Contents/Frameworks" -name "*.dylib" | while IFS= read -r lib; do
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$lib"
        done
    fi

    # Sign the main bundle
    codesign --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$APP_BUNDLE"

    echo "==> Code signing complete"
    codesign --verify --verbose "$APP_BUNDLE"
else
    echo "==> Skipping code signing (set SIGNING_IDENTITY env var to enable)"
fi

# Notarize the APP first (so the ticket can be stapled to the .app before DMG packaging)
if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARIZE_KEYCHAIN_PROFILE" ]; then
    echo "==> Notarizing app bundle..."
    APP_ZIP="$BUILD_DIR/BlazingTranscribe-app.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"

    xcrun notarytool submit "$APP_ZIP" \
        --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket to app..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    rm -f "$APP_ZIP"
    echo "==> App notarization complete"
fi

# Create styled DMG with drag-to-Applications installer
echo "==> Packaging DMG..."
rm -f "$DMG_PATH"

APP_ICON="$PROJECT_ROOT/Resources/AppIcon.icns"

if command -v create-dmg &> /dev/null && [ -f "$APP_ICON" ]; then
    echo "==> Using create-dmg for styled installer window"
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$APP_ICON" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "$APP_NAME.app" 150 185 \
        --app-drop-link 450 185 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_BUNDLE"
else
    echo "==> Fallback: basic DMG (install create-dmg for styled installer)"
    STAGING_DIR="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"
    rm -rf "$STAGING_DIR"
fi

echo "==> DMG created at $DMG_PATH"

# Sign the DMG
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
fi

# Notarize the DMG (the outermost container users download)
if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARIZE_KEYCHAIN_PROFILE" ]; then
    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket to DMG..."
    xcrun stapler staple "$DMG_PATH"
    echo "==> DMG notarization complete"
fi

# Generate Sparkle appcast for OTA updates
echo "==> Generating Sparkle appcast..."
UPDATES_DIR="$SITE_DIR/public/updates"
mkdir -p "$UPDATES_DIR"

# Copy versioned DMG for appcast + landing page download
cp "$DMG_PATH" "$UPDATES_DIR/BlazingTranscribe-${VERSION}.dmg"
cp "$DMG_PATH" "$SITE_DIR/public/BlazingTranscribe.dmg"

# Find generate_appcast tool
GENERATE_APPCAST="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ -f "$GENERATE_APPCAST" ]; then
    "$GENERATE_APPCAST" \
        --download-url-prefix "https://www.blazingfasttranscription.com/updates/" \
        -o "$UPDATES_DIR/appcast.xml" \
        "$UPDATES_DIR"
    echo "==> Appcast generated at $UPDATES_DIR/appcast.xml"
else
    echo "==> WARNING: generate_appcast not found — run 'swift build' first to get Sparkle tools"
fi

echo ""
echo "==> Done! Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "==> NEXT: commit and push the site repo to deploy:"
echo "   cd $PROJECT_ROOT/site"
echo "   git add public/BlazingTranscribe.dmg public/updates/appcast.xml public/updates/BlazingTranscribe-${VERSION}.dmg"
echo "   git commit -m 'Release v${VERSION}'"
echo "   git push"
