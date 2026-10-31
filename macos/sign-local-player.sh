#!/bin/sh
set -eu
naku_app_path=${1:?NAKU app path required}
: "${NAKU_LOCAL_SIGN_IDENTITY:?Set the approved local signing identity}"
naku_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$naku_app_path/Contents/Info.plist")
if [ "$naku_bundle_id" != 'com.shenminghao.yingchuan' ]; then
  echo 'Refusing to sign an application other than NAKU.' >&2
  exit 1
fi
# Preserve the existing sandbox/runtime flags and declared capabilities. Let
# codesign derive a fresh stable certificate-based requirement, never the old
# ad-hoc CDHash requirement. No private key is exported.
codesign --force --sign "$NAKU_LOCAL_SIGN_IDENTITY" --preserve-metadata=entitlements,flags "$naku_app_path"
codesign --verify --deep --strict "$naku_app_path"
