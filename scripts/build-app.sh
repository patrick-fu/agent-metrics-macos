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

core_bundle="$bin_dir/CodingAgentMetrics_CodingAgentMetricsCore.bundle"
if [ -d "$core_bundle" ]; then
  cp -R "$core_bundle" "$bundle/CodingAgentMetrics_CodingAgentMetricsCore.bundle"
fi

echo "$bundle"
