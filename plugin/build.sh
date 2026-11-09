#!/bin/zsh
# Headless build of ColorWindowNuke.aip (no Xcode GUI, no Illustrator needed).
#
#   plugin/build.sh                    official SDK at ~/Developer/Adobe Illustrator 2026 SDK
#   plugin/build.sh --sdk <SDKROOT>    official SDK elsewhere (also: CWN_SDK=<SDKROOT>)
#   (falls back to the dev shim in sdk-shim/ only when no SDK is found)
#   plugin/build.sh --sign "Developer ID Application: NAME (TEAMID)"
#   plugin/build.sh --universal        arm64 + x86_64 (Intel Illustrator 2024 and older)
#
# Bundle layout mirrors the SDK's own sample build (samplecode/common/mac):
#   Contents/Info.plist, PkgInfo (ARPIART5), MacOS/<exe>,
#   Resources/pipl/plugin.pipl, Resources/<exe>.rsrc (empty resource map).
set -euo pipefail
here=${0:A:h}
root=${here:h}
name=ColorWindowNuke
out=$root/build/$name.aip
# Default SDK location (kept outside the repo; never published).
default_sdk="$HOME/Developer/Adobe Illustrator 2026 SDK"
sdk=${CWN_SDK:-} identity="-" archs=(-arch arm64)
[[ -z $sdk && -f "$default_sdk/illustratorapi/illustrator/AINotifier.h" ]] && sdk=$default_sdk
while (( $# )); do
  case $1 in
    --sdk) sdk=$2; shift 2;;
    --sign) identity=$2; shift 2;;
    --universal) archs=(-arch arm64 -arch x86_64); shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done

incs=(-I"$here/src")
defs=()
if [[ -n $sdk ]]; then
  api=$sdk/illustratorapi
  [[ -f $api/illustrator/AINotifier.h ]] || { echo "not an Illustrator SDK: $sdk" >&2; exit 1; }
  # -isystem: keep -Werror for our code without failing on warnings inside Adobe headers.
  incs+=(-isystem "$api/illustrator" -isystem "$api/illustrator/actions" -isystem "$api/pica_sp" -isystem "$api/ate")
  defs+=(-DPC_OFFICIAL_SDK=1)
  flavor="official SDK ($(head -1 "$sdk/Version.txt" 2>/dev/null))"
else
  [[ -f $here/sdk-shim/PCShim.h ]] || { echo "no SDK given and no dev shim present" >&2; exit 1; }
  incs+=(-I"$here/sdk-shim")
  flavor="dev shim"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources/pipl"
cp "$here/Info.plist" "$out/Contents/Info.plist"
printf 'ARPIART5' > "$out/Contents/PkgInfo"

# PiPL: Adobe's generator when the SDK is present (it writes ./plugin.pipl and
# needs its own folder on the import path, so run it from an empty temp dir).
if [[ -n $sdk ]]; then
  (cd "$tmp" && python3 "$sdk/tools/pipl/create_pipl.py" -input '[{"name":"Color Window Nuke"}]')
  cp "$tmp/plugin.pipl" "$out/Contents/Resources/pipl/plugin.pipl"
else
  python3 -I "$here/tools/mkpipl.py" "$out/Contents/Resources/pipl/plugin.pipl" "Color Window Nuke"
fi

# Empty resource map: CSResourcesFileMapped=true makes the loader open it.
: > "$tmp/empty.r"
xcrun Rez -useDF -o "$out/Contents/Resources/$name.rsrc" "$tmp/empty.r"

xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  "${archs[@]}" -mmacosx-version-min=13.0 -bundle -fvisibility=hidden \
  "${incs[@]}" "${defs[@]}" \
  -framework Cocoa -framework QuartzCore \
  -o "$out/Contents/MacOS/$name" "$here/src/$name.mm"

opts=()
[[ $identity != "-" ]] && opts=(--options runtime --timestamp)
codesign --force --sign "$identity" "${opts[@]}" "$out"
echo "built $out ($(lipo -archs "$out/Contents/MacOS/$name"), $flavor, signed: $identity)"
