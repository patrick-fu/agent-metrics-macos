#!/bin/sh
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

swift build -c release --product CodingAgentMetricsApp --arch arm64
bin_dir="$(swift build -c release --show-bin-path --arch arm64)"
binary="$bin_dir/CodingAgentMetricsApp"
bundle="$root/.build/release/CodingAgentMetrics.app"

if [ -e "$bundle" ]; then
  /bin/rm -rf "$bundle"
fi
mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/CodingAgentMetrics"
cp "$root/Sources/CodingAgentMetricsApp/Info.plist" "$bundle/Contents/Info.plist"

sparkle_framework="$bin_dir/Sparkle.framework"
if [ ! -d "$sparkle_framework" ]; then
  echo "Missing required Sparkle.framework at $sparkle_framework" >&2
  exit 1
fi
mkdir -p "$bundle/Contents/Frameworks"
/usr/bin/ditto "$sparkle_framework" "$bundle/Contents/Frameworks/Sparkle.framework"
/usr/bin/install_name_tool \
  -add_rpath "@executable_path/../Frameworks" \
  "$bundle/Contents/MacOS/CodingAgentMetrics"

core_bundle="$bin_dir/CodingAgentMetrics_CodingAgentMetricsCore.bundle"
if [ -d "$core_bundle" ]; then
  mkdir -p "$bundle/Contents/Resources"
  cp -R "$core_bundle" "$bundle/Contents/Resources/CodingAgentMetrics_CodingAgentMetricsCore.bundle"
fi

echo "$bundle"
