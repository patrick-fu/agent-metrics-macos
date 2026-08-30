#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: scripts/build-site.sh OUTPUT_DIRECTORY" >&2
    exit 2
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output="$1"
website="$root/website"
manifest="$website/site-manifest.txt"
feed="$website/updates/appcast.xml"

if [ -L "$output" ]; then
    echo "build-site: output directory must not be a symlink: $output" >&2
    exit 2
fi
if [ -e "$output" ] && [ "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    echo "build-site: output directory must be absent or empty: $output" >&2
    exit 2
fi

if [ ! -f "$manifest" ] || [ ! -f "$feed" ]; then
    echo "build-site: site manifest or appcast is missing" >&2
    exit 2
fi

is_safe_relative_path() {
    value="$1"
    case "$value" in
        ''|/*|*'//'*) return 1 ;;
    esac
    remaining="$value"
    while :; do
        component="${remaining%%/*}"
        case "$component" in
            ''|.|..) return 1 ;;
        esac
        [ "$remaining" = "$component" ] && break
        remaining="${remaining#*/}"
    done
}

is_safe_source() {
    source="$1"
    is_safe_relative_path "$source" || return 1
    source_path="$website"
    remaining="$source"
    while :; do
        component="${remaining%%/*}"
        source_path="$source_path/$component"
        [ ! -L "$source_path" ] || return 1
        [ "$remaining" = "$component" ] && break
        remaining="${remaining#*/}"
    done
    [ -f "$source_path" ]
}

while IFS=' ' read -r source destination extra; do
    case "$source" in
        ''|'#'*) continue ;;
    esac
    if [ -z "$destination" ] || [ -n "${extra:-}" ] || ! is_safe_source "$source"; then
        echo "build-site: unsafe manifest source: $source" >&2
        exit 2
    fi
    if ! is_safe_relative_path "$destination"; then
        echo "build-site: unsafe manifest destination: $destination" >&2
        exit 2
    fi
done < "$manifest"

latest_item="$(awk '/<item>/{inside=1} inside { print } /<\/item>/{ exit }' "$feed")"
latest_version="$(printf '%s\n' "$latest_item" | sed -n 's#.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*#\1#p')"
latest_build="$(printf '%s\n' "$latest_item" | sed -n 's#.*<sparkle:version>\([^<]*\)</sparkle:version>.*#\1#p')"
latest_download_url="$(printf '%s\n' "$latest_item" | sed -n 's#.*<enclosure url="\([^"]*\)".*#\1#p')"
if [ -z "$latest_version" ] || [ -z "$latest_build" ] || [ -z "$latest_download_url" ]; then
    echo "build-site: latest appcast item is incomplete" >&2
    exit 2
fi

unexpected=false
while IFS= read -r relative; do
    [ "$relative" = "site-manifest.txt" ] && continue
    if ! awk -v path="$relative" '$1 == path { found = 1 } END { exit !found }' "$manifest"; then
        if [ "$unexpected" = false ]; then
            echo "build-site: website contains non-allowlisted files:" >&2
        fi
        printf '%s\n' "$relative" >&2
        unexpected=true
    fi
done <<EOF
$(find "$website" -type f -o -type l | sed "s#^$website/##" | sort)
EOF
if [ "$unexpected" = true ]; then
    exit 2
fi

mkdir -p "$output"
while IFS=' ' read -r source destination; do
    case "$source" in
        ''|'#'*) continue ;;
    esac
    mkdir -p "$(dirname "$output/$destination")"
    case "$source" in
        *.in)
            awk -v version="$latest_version" -v build="$latest_build" -v url="$latest_download_url" '
                {
                    rendered_url = url
                    gsub(/&/, "\\\\&", rendered_url)
                    gsub(/\{\{LATEST_VERSION\}\}/, version)
                    gsub(/\{\{LATEST_BUILD\}\}/, build)
                    gsub(/\{\{LATEST_DOWNLOAD_URL\}\}/, rendered_url)
                    print
                }
            ' "$website/$source" > "$output/$destination"
            ;;
        *) cp "$website/$source" "$output/$destination" ;;
    esac
done < "$manifest"
: > "$output/.nojekyll"

echo "build-site: $output (version $latest_version build $latest_build)"
