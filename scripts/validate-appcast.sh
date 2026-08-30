#!/bin/sh
set -eu

if [ "$#" -eq 1 ] && [ -f "$1" ]; then
    :
elif [ "$#" -eq 4 ] && [ "$1" = "--verify-archive" ] && [ -f "$2" ] && [ -f "$3" ] && [ -f "$4" ]; then
    :
else
    echo "usage: scripts/validate-appcast.sh APPCAST_XML" >&2
    echo "       scripts/validate-appcast.sh --verify-archive APPCAST_XML ARCHIVE INFO_PLIST" >&2
    exit 2
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-appcast-validator.XXXXXX")"
validator="$scratch/appcast-validator"
trap '/bin/rm -rf -- "$scratch"' EXIT HUP INT TERM

swiftc -O \
    "$root/Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift" \
    "$root/Sources/CodingAgentMetricsAppcastValidator/main.swift" \
    -o "$validator"
"$validator" "$@"
