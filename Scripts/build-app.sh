#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-debug}"
bin_path="$(cd "$project_root" && swift build -c "$configuration" --show-bin-path)"
app_path="$project_root/build/Reminder.app"
contents_path="$app_path/Contents"
resources_path="$contents_path/Resources"

mkdir -p "$contents_path/MacOS" "$resources_path"
cp "$project_root/Packaging/Info.plist" "$contents_path/Info.plist"
cp "$bin_path/Reminder" "$contents_path/MacOS/Reminder"
xcrun actool "$project_root/Resources/Assets.xcassets" \
    --compile "$resources_path" \
    --output-partial-info-plist "$contents_path/assetcatalog-info.plist" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon

find "$bin_path" -maxdepth 1 -type d -name "*.bundle" -exec cp -R {} "$resources_path" \;

echo "已生成：$app_path"
