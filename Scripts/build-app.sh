#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-debug}"
bin_path="$(cd "$project_root" && swift build -c "$configuration" --show-bin-path)"
app_path="$project_root/build/Reminder.app"
contents_path="$app_path/Contents"
resources_path="$contents_path/Resources"
applications_path="${APPLICATIONS_DIR:-/Applications}"
installed_app_path="$applications_path/Reminder.app"
staging_app_path="$applications_path/.Reminder.app.installing.$$"
backup_app_path="$applications_path/.Reminder.app.backup.$$"

run_installer_command() {
    if [[ -w "$applications_path" ]]; then
        command "$@"
    else
        sudo "$@"
    fi
}

cleanup_installation() {
    if [[ -e "$staging_app_path" ]]; then
        run_installer_command rm -rf "$staging_app_path"
    fi
}

trap cleanup_installation EXIT

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

run_installer_command ditto "$app_path" "$staging_app_path"

if [[ -e "$installed_app_path" ]]; then
    run_installer_command rm -rf "$backup_app_path"
    run_installer_command mv "$installed_app_path" "$backup_app_path"
fi

if run_installer_command mv "$staging_app_path" "$installed_app_path"; then
    run_installer_command rm -rf "$backup_app_path"
else
    if [[ -e "$backup_app_path" ]]; then
        run_installer_command mv "$backup_app_path" "$installed_app_path"
    fi
    echo "安装失败，已恢复原有 Reminder.app。" >&2
    exit 1
fi

trap - EXIT
echo "已安装并替换：$installed_app_path"
