#!/bin/sh
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
build_dir="${CODING_AGENT_METRICS_BUILD_DIR:-$root/.build}"
bundle="$build_dir/release/Agent Metrics.app"
dmg_dir="${CODING_AGENT_METRICS_DMG_DIR:-$build_dir/release}"

"$root/scripts/build-app.sh"

if [ ! -d "$bundle" ]; then
  echo "Missing release app bundle at $bundle" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
if [ -z "$version" ]; then
  echo "Missing CFBundleShortVersionString in release app bundle" >&2
  exit 1
fi

dmg="$dmg_dir/AgentMetrics-$version.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-dmg.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT HUP INT TERM

mkdir -p "$dmg_dir"
cp -R "$bundle" "$stage/Agent Metrics.app"
ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -format UDZO -ov -volname "Agent Metrics" -srcfolder "$stage" "$dmg"

echo "$dmg"
