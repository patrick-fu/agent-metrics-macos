#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: scripts/build-site.sh OUTPUT_DIRECTORY" >&2
    exit 2
fi

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output="$1"

if [ -e "$output" ] && [ "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    echo "build-site: output directory must be absent or empty: $output" >&2
    exit 2
fi

mkdir -p "$output"
unexpected=false
while IFS= read -r relative; do
    case "$relative" in
        assets/favicon.svg|assets/summary-popover-2x.png|index.html|styles.css|updates/appcast.xml) ;;
        *)
            if [ "$unexpected" = false ]; then
                echo "build-site: website contains non-allowlisted files:" >&2
            fi
            printf '%s\n' "$relative" >&2
            unexpected=true
            ;;
esac
done <<EOF
$(find "$root/website" -type f -o -type l | sed "s#^$root/website/##" | sort)
EOF
if [ "$unexpected" = true ]; then
    exit 2
fi

cp "$root/website/index.html" "$output/index.html"
cp "$root/website/styles.css" "$output/styles.css"
mkdir -p "$output/assets" "$output/updates"
cp "$root/website/assets/favicon.svg" "$output/assets/favicon.svg"
cp "$root/website/assets/summary-popover-2x.png" "$output/assets/summary-popover-2x.png"
cp "$root/website/updates/appcast.xml" "$output/updates/appcast.xml"
: > "$output/.nojekyll"

echo "build-site: $output"
