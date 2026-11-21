#!/bin/sh
set -eu
app=${1:?path to built NAKUPlayer.app}
cache=${2:?path to build cache}
identity=${NAKU_LOCAL_SIGN_IDENTITY:--}
here=$(cd "$(dirname "$0")" && pwd)
case "$(uname -m)" in
  arm64) arch=arm64; digest=3f82946fde29082da4a509f2331b7c1227f8920898318bf361ed06f2a7b370c1 ;;
  x86_64) arch=amd64; digest=299d7367f51d9f37510413df411c040ee970f32dd1a70dd8d87878c24938830e ;;
  *) exit 2 ;;
esac
version=MatriX.151
artifact="$cache/TorrServer-$version-$arch"
mkdir -p "$cache" "$app/Contents/Helpers" "$app/Contents/Resources/OriginalMedia"
verify() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$digest" ]; }
if ! verify "$artifact"; then
  /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 120 \
    "https://github.com/YouROK/TorrServer/releases/download/$version/TorrServer-darwin-$arch" -o "$artifact.part"
  verify "$artifact.part"
  mv "$artifact.part" "$artifact"
fi
install -m 755 "$artifact" "$app/Contents/Helpers/TorrServer"
xcrun clang -Wall -Wextra -Werror -Os -mmacosx-version-min=12.0 "$here/supervisor.c" -o "$app/Contents/Helpers/NakuOriginalHost"
for binary in TorrServer NakuOriginalHost; do
    codesign --force --sign "$identity" --entitlements "$here/inherit.plist" "$app/Contents/Helpers/$binary"
done
cp "$here/LICENSE-TorrServer" "$app/Contents/Resources/OriginalMedia/LICENSE"
echo "TorrServer $version — https://github.com/YouROK/TorrServer/tree/$version" > "$app/Contents/Resources/OriginalMedia/Source.txt"
