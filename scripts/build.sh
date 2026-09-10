#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

derived="${root}/build"
dist="${root}/dist"
app_name="AI Usage Widget.app"

rm -rf "$dist"
mkdir -p "$dist"

xcodebuild \
  -project AIUsageWidgetKit.xcodeproj \
  -scheme "AI Usage Widget" \
  -configuration Release \
  -derivedDataPath "$derived" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES

product="${derived}/Build/Products/Release/${app_name}"
if [[ ! -d "$product" ]]; then
  echo "build product missing: $product" >&2
  exit 1
fi

cp -R "$product" "$dist/"
echo "built: ${dist}/${app_name}"
