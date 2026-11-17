#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
swift build -j 2 --product agent-beacon-app
swift build -j 2 --product agent-beacon
binary_dir="$(swift build --show-bin-path)"
if [ "$#" -gt 1 ]; then
  printf '%s\n' "Usage: build-app.sh [absolute-output-app-path]" >&2
  exit 1
fi
app_dir="${1:-$repo_dir/dist/Agent Beacon.app}"
if [[ "$app_dir" != /*.app ]]; then
  printf '%s\n' "The output path must be an absolute .app path" >&2
  exit 1
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/agent-beacon-app" "$app_dir/Contents/MacOS/AgentBeacon"
cp "$binary_dir/agent-beacon" "$app_dir/Contents/MacOS/agent-beacon"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.agentbeacon.mac</string>
  <key>CFBundleName</key><string>Agent Beacon</string>
  <key>CFBundleDisplayName</key><string>Agent Beacon</string>
  <key>CFBundleExecutable</key><string>AgentBeacon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>NSLocalNetworkUsageDescription</key><string>Share live agent status and statistics with your paired Agent Beacon iPhone.</string>
  <key>NSBonjourServices</key><array><string>_agentbeacon._tcp</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
