#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
package_path="$project_root/SolisMenuBar"
configuration="${1:-release}"
output_root="$project_root/build/menubar"
app_path="$output_root/SolisMenuBar.app"

swift build --disable-sandbox --package-path "$package_path" --configuration "$configuration"
binary_path="$(swift build --disable-sandbox --package-path "$package_path" --configuration "$configuration" --show-bin-path)/SolisMenuBar"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/SolisMenuBar"
cp "$package_path/Resources/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --deep --sign - "$app_path"

echo "$app_path"
