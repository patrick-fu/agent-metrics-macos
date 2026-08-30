#!/bin/sh
set -eu

usage() {
    cat <<'USAGE'
usage: scripts/deploy-pages.sh --legacy-repo PATH [--publish]
       scripts/deploy-pages.sh --preflight-site PATH

Builds the canonical website from main into temporary local worktrees.
Without --publish, stages and reports both Pages diffs without committing or pushing.
With --publish, pushes the primary site and the matching frozen feed in the legacy repo.

Required:
  --legacy-repo PATH  Local checkout of patrick-fu/coding-agent-metrics.

Options:
  --publish           Commit and push both gh-pages branches.
  --preflight-site PATH
                      Verify the newest built appcast artifact is publicly downloadable.
  --help              Show this help.
USAGE
}

legacy_repo=""
publish=false
preflight_site=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --legacy-repo)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            legacy_repo="$2"
            shift 2
            ;;
        --publish)
            publish=true
            shift
            ;;
        --preflight-site)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            preflight_site="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$preflight_site" ]; then
    if [ -n "$legacy_repo" ] || [ "$publish" = true ]; then
        usage >&2
        exit 2
    fi
elif [ -z "$legacy_repo" ]; then
    usage >&2
    exit 2
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

fail_preflight() {
    echo "deploy-pages: $1" >&2
    exit 2
}

single_value() {
    values="$1"
    label="$2"
    count="$(printf '%s\n' "$values" | awk 'NF { count += 1 } END { print count + 0 }')"
    [ "$count" -eq 1 ] || fail_preflight "latest appcast item must contain exactly one $label"
    printf '%s\n' "$values" | awk 'NF { print; exit }'
}

attribute_value() {
    attribute="$1"
    input="$2"
    printf '%s\n' "$input" | sed -n "s/.* ${attribute}=\"\\([^\"]*\\)\".*/\\1/p"
}

preflight_release_artifact() {
    site_dir="$1"
    appcast="$site_dir/updates/appcast.xml"
    [ -f "$appcast" ] || fail_preflight "built site is missing updates/appcast.xml"
    if ! /bin/sh "$root/scripts/validate-appcast.sh" "$appcast"; then
        fail_preflight "production update contract rejected"
    fi

    latest_item="$(awk '
        /<item[ >]/ { in_item = 1 }
        in_item { print }
        in_item && /<\/item>/ { exit }
    ' "$appcast")"
    [ -n "$latest_item" ] || fail_preflight "built appcast has no item"

    enclosure="$(single_value "$(printf '%s\n' "$latest_item" | sed -n '/<enclosure[ >]/p')" enclosure)"
    release_url="$(single_value "$(attribute_value url "$enclosure")" enclosure URL)"
    archive_length="$(single_value "$(attribute_value length "$enclosure")" enclosure length)"
    short_version="$(single_value "$(printf '%s\n' "$latest_item" | sed -n 's#.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*#\1#p')" short version)"
    build="$(single_value "$(printf '%s\n' "$latest_item" | sed -n 's#.*<sparkle:version>\([^<]*\)</sparkle:version>.*#\1#p')" build)"
    minimum_system_versions="$(printf '%s\n' "$latest_item" | sed -n 's#.*<sparkle:minimumSystemVersion>\([^<]*\)</sparkle:minimumSystemVersion>.*#\1#p')"
    minimum_system_version_count="$(printf '%s\n' "$minimum_system_versions" | awk 'NF { count += 1 } END { print count + 0 }')"
    [ "$minimum_system_version_count" -eq 1 ] || fail_preflight "latest appcast minimum macOS mismatch (expected 14.0, got missing)"
    minimum_system_version="$(printf '%s\n' "$minimum_system_versions" | awk 'NF { print; exit }')"

    case "$release_url" in
        https://*) ;;
        *) fail_preflight "latest appcast enclosure URL must use HTTPS" ;;
    esac
    case "$archive_length" in
        ''|*[!0-9]*) fail_preflight "latest appcast enclosure length must be a positive integer" ;;
    esac
    [ "$archive_length" -gt 0 ] || fail_preflight "latest appcast enclosure length must be a positive integer"
    case "$build" in
        ''|*[!0-9]*) fail_preflight "latest appcast build must be a positive integer" ;;
    esac
    [ "$build" -gt 0 ] || fail_preflight "latest appcast build must be a positive integer"
    [ "$minimum_system_version" = "14.0" ] || fail_preflight "latest appcast minimum macOS mismatch (expected 14.0, got ${minimum_system_version:-missing})"
    case "$short_version" in
        ''|*[!0-9.]*|.*|*.|*..*) fail_preflight "latest appcast short version is invalid" ;;
    esac

    expected_filename="AgentMetrics-${short_version}.dmg"
    expected_url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v${short_version}/${expected_filename}"
    [ "$release_url" = "$expected_url" ] || fail_preflight "latest appcast URL mismatch (expected $expected_url, got $release_url)"

    preflight_directory="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-pages-preflight.XXXXXX")" || fail_preflight "could not create temporary download directory"
    headers="$preflight_directory/headers"
    transfer="$preflight_directory/transfer"
    if ! (
        cd "$preflight_directory"
        curl -q -L -sS -D "$headers" -O -J -w '%{http_code}\n%{size_download}\n' "$release_url" > "$transfer"
    ); then
        /bin/rm -rf -- "$preflight_directory"
        fail_preflight "could not download latest appcast DMG"
    fi

    http_status="$(sed -n '1p' "$transfer")"
    downloaded_size="$(sed -n '2p' "$transfer")"
    case "$http_status" in
        2??) ;;
        *)
            /bin/rm -rf -- "$preflight_directory"
            fail_preflight "latest appcast DMG preflight failed (HTTP ${http_status:-unknown})"
            ;;
    esac

    downloaded_files="$(find "$preflight_directory" -type f ! -name headers ! -name transfer -print)"
    downloaded_file="$(single_value "$downloaded_files" downloaded DMG)"
    downloaded_filename="$(basename "$downloaded_file")"
    if [ "$downloaded_filename" != "$expected_filename" ]; then
        /bin/rm -rf -- "$preflight_directory"
        fail_preflight "latest appcast DMG final filename mismatch (expected $expected_filename, got $downloaded_filename)"
    fi

    actual_size="$(wc -c < "$downloaded_file" | tr -d ' ')"
    if [ "$downloaded_size" != "$archive_length" ] || [ "$actual_size" != "$archive_length" ]; then
        /bin/rm -rf -- "$preflight_directory"
        fail_preflight "latest appcast DMG byte length mismatch (expected $archive_length, curl ${downloaded_size:-unknown}, file $actual_size)"
    fi
    if ! /bin/sh "$root/scripts/validate-appcast.sh" --verify-archive "$appcast" "$downloaded_file" "$root/Sources/CodingAgentMetricsApp/Info.plist"; then
        /bin/rm -rf -- "$preflight_directory"
        fail_preflight "latest appcast DMG signature verification failed"
    fi

    /bin/rm -rf -- "$preflight_directory"
    echo "deploy-pages: release preflight passed: $short_version ($build), $expected_filename, $archive_length bytes"
}

if [ -n "$preflight_site" ]; then
    preflight_release_artifact "$preflight_site"
    exit 0
fi

legacy_repo="$(CDPATH= cd -- "$legacy_repo" && pwd)"

require_origin() {
    repo="$1"
    expected="$2"
    label="$3"
    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
        "git@github.com:patrick-fu/$expected"|"git@github.com:patrick-fu/$expected.git"|\
        "https://github.com/patrick-fu/$expected"|"https://github.com/patrick-fu/$expected.git"|\
        "ssh://git@github.com/patrick-fu/$expected"|"ssh://git@github.com/patrick-fu/$expected.git"|\
        "git+ssh://git@github.com/patrick-fu/$expected"|"git+ssh://git@github.com/patrick-fu/$expected.git")
            ;;
        *)
            echo "deploy-pages: $label origin must be exactly patrick-fu/$expected (got: ${remote:-missing})" >&2
            exit 2
            ;;
    esac
}

if [ "$(git -C "$root" branch --show-current)" != "main" ]; then
    echo "deploy-pages: canonical website must be deployed from main" >&2
    exit 2
fi
release_contract_paths="website scripts/build-site.sh scripts/deploy-pages.sh scripts/validate-appcast.sh Sources/CodingAgentMetricsAppcastValidator/main.swift Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift"
if ! git -C "$root" diff --quiet HEAD -- $release_contract_paths; then
    echo "deploy-pages: commit website and deployment changes before deploying" >&2
    exit 2
fi
if [ -n "$(git -C "$root" ls-files --others --exclude-standard -- $release_contract_paths)" ]; then
    echo "deploy-pages: commit website and deployment changes before deploying" >&2
    exit 2
fi
if ! git -C "$legacy_repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "deploy-pages: --legacy-repo must be a local Git checkout" >&2
    exit 2
fi
require_origin "$root" agent-metrics-macos primary
require_origin "$legacy_repo" coding-agent-metrics legacy
if ! git -C "$root" show-ref --verify --quiet refs/heads/gh-pages; then
    echo "deploy-pages: local primary gh-pages branch is required; fetch it first" >&2
    exit 2
fi
if ! git -C "$legacy_repo" show-ref --verify --quiet refs/heads/gh-pages; then
    echo "deploy-pages: local legacy gh-pages branch is required; fetch it first" >&2
    exit 2
fi
if ! git -C "$legacy_repo" diff --quiet HEAD || [ -n "$(git -C "$legacy_repo" ls-files --others --exclude-standard)" ]; then
    echo "deploy-pages: legacy checkout must be clean" >&2
    exit 2
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-pages-deploy.XXXXXX")"
site="$scratch/site"
primary_worktree="$scratch/primary-pages"
legacy_worktree="$scratch/legacy-pages"
primary_added=false
legacy_added=false

cleanup() {
    if [ "$legacy_added" = true ]; then
        git -C "$legacy_repo" worktree remove --force "$legacy_worktree" >/dev/null 2>&1 || true
    fi
    if [ "$primary_added" = true ]; then
        git -C "$root" worktree remove --force "$primary_worktree" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM

"$root/scripts/build-site.sh" "$site"

if [ "$publish" = true ]; then
    preflight_release_artifact "$site"
fi

git -C "$root" worktree add "$primary_worktree" gh-pages >/dev/null
primary_added=true
git -C "$legacy_repo" worktree add "$legacy_worktree" gh-pages >/dev/null
legacy_added=true

git -C "$primary_worktree" rm -r --ignore-unmatch . >/dev/null
git -C "$primary_worktree" clean -fdx >/dev/null
cp -R "$site/." "$primary_worktree/"
git -C "$primary_worktree" add -A

mkdir -p "$legacy_worktree/updates"
cp "$site/updates/appcast.xml" "$legacy_worktree/updates/appcast.xml"
git -C "$legacy_worktree" add updates/appcast.xml

echo "deploy-pages: primary Pages diff"
git -C "$primary_worktree" diff --cached --stat
echo "deploy-pages: legacy feed diff"
git -C "$legacy_worktree" diff --cached --stat

if [ "$publish" = false ]; then
    echo "deploy-pages: dry run complete; rerun with --publish after reviewing both diffs"
    exit 0
fi

if ! git -C "$primary_worktree" diff --cached --quiet; then
    GIT_AUTHOR_NAME="Patrick Fu" GIT_AUTHOR_EMAIL="paaatrickfu@gmail.com" \
    GIT_COMMITTER_NAME="Patrick Fu" GIT_COMMITTER_EMAIL="paaatrickfu@gmail.com" \
        git -C "$primary_worktree" commit -m "Publish Agent Metrics website"
fi
if ! git -C "$legacy_worktree" diff --cached --quiet; then
    GIT_AUTHOR_NAME="Patrick Fu" GIT_AUTHOR_EMAIL="paaatrickfu@gmail.com" \
    GIT_COMMITTER_NAME="Patrick Fu" GIT_COMMITTER_EMAIL="paaatrickfu@gmail.com" \
        git -C "$legacy_worktree" commit -m "Sync Agent Metrics stable appcast"
fi

git -C "$primary_worktree" push origin gh-pages:gh-pages
git -C "$legacy_worktree" push origin gh-pages:gh-pages
echo "deploy-pages: published primary Pages and synchronized the legacy feed"
