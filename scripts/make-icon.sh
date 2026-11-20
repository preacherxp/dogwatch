#!/bin/sh
# Renders Support/AppIcon.svg (128 px and up) and Support/AppIcon-small.svg (16 to 64 px)
# with headless Chrome, then builds Support/AppIcon.icns with iconutil.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

render() { # svg, png: a 1024 px PNG with a transparent background
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size=1024,1024 \
        --user-data-dir="$work/chrome" --screenshot="$2" "file://$1" >/dev/null 2>&1
    [ -s "$2" ] || { echo "Chrome did not render $1" >&2; exit 1; }
}

render "$project_dir/Support/AppIcon.svg" "$work/large.png"
render "$project_dir/Support/AppIcon-small.svg" "$work/small.png"

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        name="icon_${size}x${size}"
        [ "$scale" = 2 ] && name="${name}@2x"
        source="$work/large.png"
        [ "$pixels" -le 64 ] && source="$work/small.png"
        sips -z "$pixels" "$pixels" "$source" --out "$iconset/$name.png" >/dev/null
    done
done

iconutil -c icns "$iconset" -o "$project_dir/Support/AppIcon.icns"
cp "$work/large.png" "$project_dir/docs/icon.png"
echo "Built: $project_dir/Support/AppIcon.icns and docs/icon.png"
