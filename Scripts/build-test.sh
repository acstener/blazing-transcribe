#!/bin/bash
# Build a locally signed, fully functional app without publishing or auto-updates.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
TEST_BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
TEST_BUILD_DIR="$PROJECT_ROOT/build/test-$TEST_BUILD_STAMP"
TEST_APP="$TEST_BUILD_DIR/Blazing Transcribe.app"
swift build -c release --force-resolved-versions
python3 Scripts/package-swiftpm-resources.py
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources" "$TEST_APP/Contents/Frameworks"
cp .build/release/BlazingFastTranscription "$TEST_APP/Contents/MacOS/Blazing Transcribe"
cp Resources/AppIcon.icns "$TEST_APP/Contents/Resources/AppIcon.icns"
ditto .build/release/Sparkle.framework "$TEST_APP/Contents/Frameworks/Sparkle.framework"
# Bundle resources in the standard macOS location.
for resource in .build/release/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$TEST_APP/Contents/Resources/$(basename "$resource")"
done
python3 - "$TEST_APP" "$TEST_BUILD_STAMP" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={
'CFBundleName':'Blazing Transcribe','CFBundleDisplayName':'Blazing Transcribe',
'CFBundleIdentifier':'com.blazingtranscribe.app','CFBundleExecutable':'Blazing Transcribe',
'CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.1.2',
'CFBundleVersion':sys.argv[2].replace('-','.'), 'LSMinimumSystemVersion':'15.0',
'LSUIElement':True,'LSApplicationCategoryType':'public.app-category.productivity',
'CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,
'NSMicrophoneUsageDescription':'Blazing Transcribe uses your microphone to turn your speech into text.',
'NSAccessibilityUsageDescription':'Blazing Transcribe types your dictation into the app you are using.',
'BlazingLocalTestBuild':True,'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,
}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
# Resolve bundled frameworks without relying on the build directory.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$TEST_APP/Contents/MacOS/Blazing Transcribe"
# Sign nested code inside-out for hardened runtime library validation.
while IFS= read -r -d '' nested; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested"
done < <(find "$TEST_APP/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' -o -name '*.framework' \) -print0)
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --entitlements BlazingTranscribe.entitlements "$TEST_APP"
codesign --verify --deep --strict --verbose=2 "$TEST_APP"
printf '%s\n' "$TEST_APP" > "$PROJECT_ROOT/build/latest-test-build.txt"
printf 'Test app: %s\n' "$TEST_APP"
