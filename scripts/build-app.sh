#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
if [ "$#" -gt 1 ]; then
  printf '%s\n' "Usage: build-app.sh [absolute-output-app-path]" >&2
  exit 1
fi
app_dir="${1:-$repo_dir/dist/Swarmbell.app}"
if [[ "$app_dir" != /*.app ]]; then
  printf '%s\n' "The output path must be an absolute .app path" >&2
  exit 1
fi

# Universal releases support both Apple silicon and Intel Macs. Local developers
# may select one architecture with SWARMBELL_ARCHS=arm64 (or x86_64).
configuration="${SWARMBELL_BUILD_CONFIGURATION:-release}"
read -r -a architectures <<< "${SWARMBELL_ARCHS:-arm64 x86_64}"
build_options=(-c "$configuration" -j 2)
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64|x86_64) build_options+=(--arch "$architecture") ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
  esac
done
swift build "${build_options[@]}" --product swarmbell-app
swift build "${build_options[@]}" --product swarmbell
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Remove only our generated executable names, including the old case-colliding
# main. Default macOS filesystems treat Swarmbell and swarmbell as the same file.
rm -f "$app_dir/Contents/MacOS/Swarmbell" "$app_dir/Contents/MacOS/swarmbell" \
  "$app_dir/Contents/MacOS/SwarmbellApp" "$app_dir/Contents/MacOS/agent-beacon"
cp "$binary_dir/swarmbell-app" "$app_dir/Contents/MacOS/SwarmbellApp"
cp "$binary_dir/swarmbell" "$app_dir/Contents/MacOS/swarmbell"
# Keep read-only integrations using the pre-rebrand bundled helper path working.
ln -sfn swarmbell "$app_dir/Contents/MacOS/agent-beacon"
if [ -f "$repo_dir/Resources/Swarmbell.icns" ]; then
  cp "$repo_dir/Resources/Swarmbell.icns" "$app_dir/Contents/Resources/Swarmbell.icns"
else
  printf '%s\n' "Warning: Resources/Swarmbell.icns is missing; bundle has no custom icon." >&2
fi
# Bundle ID, Bonjour service and storage identifiers intentionally retain their
# original values so updates preserve preferences, history and phone pairings.
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.agentbeacon.mac</string>
  <key>CFBundleName</key><string>Swarmbell</string>
  <key>CFBundleDisplayName</key><string>Swarmbell</string>
  <key>CFBundleExecutable</key><string>SwarmbellApp</string>
  <key>CFBundleIconFile</key><string>Swarmbell.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>NSLocalNetworkUsageDescription</key><string>Share live agent status and statistics with your paired Swarmbell iPhone.</string>
  <key>NSBonjourServices</key><array><string>_agentbeacon._tcp</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST

# Verify the executable declared by macOS resolves to the app product, never
# its CLI helper. This catches case-insensitive filename collisions in builds.
declared_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_dir/Contents/Info.plist")"
main_binary="$app_dir/Contents/MacOS/$declared_executable"
helper_binary="$app_dir/Contents/MacOS/swarmbell"
if [ "$declared_executable" != "SwarmbellApp" ] || [ ! -x "$main_binary" ] \
  || [ "$main_binary" -ef "$helper_binary" ] || cmp -s "$main_binary" "$helper_binary" \
  || ! cmp -s "$binary_dir/swarmbell-app" "$main_binary" \
  || ! cmp -s "$binary_dir/swarmbell" "$helper_binary"; then
  printf '%s\n' "Packaging failed: the app and CLI must be distinct matching build products." >&2
  exit 1
fi

# No signing identity is assumed. The default is an ad-hoc development build,
# not a Developer ID signed or notarized public release. An explicitly supplied
# identity may be used by a properly provisioned release environment.
signing_identity="${SWARMBELL_SIGNING_IDENTITY:--}"
signing_options=(--force --sign "$signing_identity")
if [ "$signing_identity" != "-" ]; then
  signing_options+=(--options runtime --timestamp)
else
  printf '%s\n' "Building an ad-hoc signed, unnotarized test release." >&2
fi
codesign "${signing_options[@]}" "$app_dir/Contents/MacOS/swarmbell"
codesign "${signing_options[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
