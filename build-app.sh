#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir="$project_dir/dist/Dogwatch.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
swift build -c release --disable-sandbox

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp ".build/release/Dogwatch" "$contents_dir/MacOS/Dogwatch"
cp "Support/Info.plist" "$contents_dir/Info.plist"
cp "Support/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
chmod +x "$contents_dir/MacOS/Dogwatch"

# Ad hoc signature: seals the bundle so macOS can verify it hasn't changed.
# It is not a Developer ID signature, so Gatekeeper still blocks a downloaded copy.
codesign --force --sign - "$app_dir"

echo "Built: $app_dir"
