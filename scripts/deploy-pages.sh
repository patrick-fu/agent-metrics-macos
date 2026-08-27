#!/bin/sh
set -eu

usage() {
    cat <<'USAGE'
usage: scripts/deploy-pages.sh --legacy-repo PATH [--publish]

Builds the canonical website from main into temporary local worktrees.
Without --publish, stages and reports both Pages diffs without committing or pushing.
With --publish, pushes the primary site and the matching frozen feed in the legacy repo.

Required:
  --legacy-repo PATH  Local checkout of patrick-fu/coding-agent-metrics.

Options:
  --publish           Commit and push both gh-pages branches.
  --help              Show this help.
USAGE
}

legacy_repo=""
publish=false
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

[ -n "$legacy_repo" ] || { usage >&2; exit 2; }

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
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
if ! git -C "$root" diff --quiet HEAD -- website scripts/build-site.sh scripts/deploy-pages.sh; then
    echo "deploy-pages: commit website and deployment changes before deploying" >&2
    exit 2
fi
if [ -n "$(git -C "$root" ls-files --others --exclude-standard -- website scripts/build-site.sh scripts/deploy-pages.sh)" ]; then
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
    release_urls="$(sed -n 's#.*href="\(https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0\.2\.0/[^" ]*\.dmg\)".*#\1#p' "$site/index.html")"
    release_url_count="$(printf '%s\n' "$release_urls" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$release_url_count" -ne 1 ]; then
        echo "deploy-pages: could not find the unique v0.2.0 DMG URL in website/index.html" >&2
        exit 2
    fi
    release_url="$release_urls"
    http_status="$(curl -L -sS -o /dev/null -w '%{http_code}' "$release_url" || true)"
    case "$http_status" in
        2??) ;;
        *)
            echo "deploy-pages: v0.2.0 DMG URL preflight failed (HTTP ${http_status:-unknown})" >&2
            exit 2
            ;;
    esac
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
