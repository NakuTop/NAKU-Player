#!/bin/sh
set -eu
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${1:?package output path required}
scratch=${2:?build scratch path required}
payload="$scratch/payload"
driver="$payload/Library/Audio/Plug-Ins/HAL/NAKUAudio.driver"
broker="$payload/Library/PrivilegedHelperTools/com.shenminghao.naku.audio-broker"
scripts="$scratch/scripts"
mkdir -p "$driver/Contents/MacOS" "$(dirname "$broker")" "$payload/Library/LaunchDaemons" \
  "$payload/Library/Application Support/NAKUAudio" "$scripts" "$(dirname "$output")"
xcrun clang -std=c11 -fblocks -O2 -fvisibility=hidden -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -bundle "$source_dir/Driver/NakuAudioDriver.c" -framework CoreAudio -framework CoreFoundation \
  -o "$driver/Contents/MacOS/NAKUAudio"
cp "$source_dir/Driver/Info.plist" "$driver/Contents/Info.plist"
xcrun clang -std=c11 -fblocks -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  "$source_dir/Broker/NakuAudioBroker.c" -framework CoreAudio -framework CoreFoundation \
  -framework Security -framework SystemConfiguration -o "$broker"
codesign --force --sign - --identifier com.shenminghao.naku.audio-driver "$driver"
codesign --force --sign - --identifier com.shenminghao.naku.audio-broker "$broker"
codesign --verify --strict "$driver"
codesign --verify --strict "$broker"
cp "$source_dir/Installer/com.shenminghao.naku.audio-broker.plist" "$payload/Library/LaunchDaemons/"
cp "$source_dir/Installer/postinstall" "$scripts/postinstall"
chmod 755 "$scripts/postinstall" "$broker"
chmod 644 "$payload/Library/LaunchDaemons/com.shenminghao.naku.audio-broker.plist"
pkgbuild --root "$payload" --scripts "$scripts" --identifier com.shenminghao.naku.audio-driver \
  --version 1.0.2 --ownership recommended --install-location / "$output"
authorization_scripts="$scratch/authorization-scripts"
mkdir -p "$authorization_scripts"
cp "$source_dir/Installer/authorize-postinstall" "$authorization_scripts/postinstall"
chmod 755 "$authorization_scripts/postinstall"
pkgbuild --nopayload --scripts "$authorization_scripts" --identifier com.shenminghao.naku.audio-authorization \
  --version 1.0.0 --install-location / "$(dirname "$output")/NAKUAudioAuthorization.pkg"
