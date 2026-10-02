#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 APP_BUNDLE SIGNING_IDENTITY [swift build options...]" >&2
    echo "Set SANDBOX=1 for sandbox inheritance; use '-' for local ad-hoc signing." >&2
    exit 2
fi
app_bundle="$1"
signing_identity="$2"
shift 2
package_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$app_bundle" != *.app || ! -f "$app_bundle/Contents/Info.plist" ]]; then
    echo "Expected an existing .app bundle with Contents/Info.plist." >&2
    exit 2
fi
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")
if [[ -z "$bundle_identifier" || -z "$signing_identity" ]]; then
    echo "The app bundle identifier and signing identity must not be empty." >&2
    exit 2
fi
swift build --package-path "$package_root" -c release --product AppLifecycleRecoveryHelper "$@"
binary_directory="$(swift build --package-path "$package_root" -c release --show-bin-path "$@")"
destination="$app_bundle/Contents/MacOS/AppLifecycleRecoveryHelper"
mkdir -p "$(dirname "$destination")"
cp "$binary_directory/AppLifecycleRecoveryHelper" "$destination"
chmod 755 "$destination"
sign_arguments=(--force --sign "$signing_identity" --identifier "$bundle_identifier.recovery")
if [[ "$signing_identity" != '-' ]]; then
    sign_arguments+=(--options runtime --timestamp)
fi
if [[ "${SANDBOX:-0}" == 1 ]]; then
    sign_arguments+=(--entitlements "$package_root/Support/RecoveryHelper.entitlements")
fi
codesign "${sign_arguments[@]}" "$destination"
codesign --verify --strict "$destination"
echo "Helper embedded. Sign the containing app bundle next."
