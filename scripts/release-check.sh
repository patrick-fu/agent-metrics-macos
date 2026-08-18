#!/bin/sh
set -eu

case "${1---dry-run}" in
    --dry-run) ;;
    *)
        echo "release-check result=FAIL reason=only-dry-run-is-supported"
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    echo "release-check result=FAIL reason=only-dry-run-is-supported"
    exit 2
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/coding-agent-metrics-release-check.XXXXXX")"
output="$scratch/output"
compiler_output="$scratch/compiler-output"
checker="$scratch/release-checker"
trap '/bin/rm -rf -- "$scratch"' EXIT HUP INT TERM

cd "$root"
if ! swiftc -O \
    Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift \
    Sources/CodingAgentMetricsLifecycle/ReleasePipelineContract.swift \
    Sources/CodingAgentMetricsLifecycle/ReleaseDryRunChecker.swift \
    Sources/CodingAgentMetricsReleaseCheck/main.swift \
    -o "$checker" >"$compiler_output" 2>&1; then
    echo "release-check result=FAIL reason=local-checker-unavailable"
    exit 1
fi
if ! "$checker" --dry-run >"$output" 2>&1; then
    echo "release-check result=FAIL reason=synthetic-contract-rejected"
    exit 1
fi
if ! /usr/bin/grep -q '^release-check result=PASS mode=synthetic-dry-run ' "$output"; then
    echo "release-check result=FAIL reason=synthetic-contract-rejected"
    exit 1
fi

/usr/bin/sed -n '/^release-check /p' "$output"
