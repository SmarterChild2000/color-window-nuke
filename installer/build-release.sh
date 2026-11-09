#!/bin/zsh
# Build the downloadable release: dist/ColorWindowNuke-<version>.dmg containing
#   Install Color Window Nuke.pkg, Uninstall Color Window Nuke.pkg, Read Me.txt
#
#   installer/build-release.sh                       unsigned (ad-hoc signed plug-in)
#   installer/build-release.sh \
#     --sign-app "Developer ID Application: NAME (TEAMID)" \
#     --sign-installer "Developer ID Installer: NAME (TEAMID)" \
#     --notarize <notarytool keychain profile>          signed + notarized + stapled
set -euo pipefail
here=${0:A:h}
root=${here:h}
app_id="-" inst_id="" notary=""
while (( $# )); do
  case $1 in
    --sign-app) app_id=$2; shift 2;;
    --sign-installer) inst_id=$2; shift 2;;
    --notarize) notary=$2; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ -n $notary && -z $inst_id ]] && { echo "--notarize needs --sign-installer" >&2; exit 2; }

ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$root/plugin/Info.plist")
dist=$root/dist
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$dist"

echo "== plug-in $ver"
if [[ $app_id == "-" ]]; then "$root/plugin/build.sh"; else "$root/plugin/build.sh" --sign "$app_id"; fi
aip=$root/build/ColorWindowNuke.aip

echo "== install package"
mkdir -p "$tmp/root/Library/Application Support/ColorWindowNuke"
# Copy without extended attributes (Dropbox/provenance metadata on the build
# folder), or pkgbuild packs them as ._AppleDouble files into the payload.
ditto --norsrc --noextattr --noqtn --noacl "$aip" "$tmp/root/Library/Application Support/ColorWindowNuke/ColorWindowNuke.aip"
for d in install uninstall; do
  mkdir -p "$tmp/scripts-$d"
  ditto --norsrc --noextattr --noqtn --noacl "$here/pkg/$d/postinstall" "$tmp/scripts-$d/postinstall"
  chmod 755 "$tmp/scripts-$d/postinstall"
done
ditto --norsrc --noextattr --noqtn --noacl "$here/pkg/resources" "$tmp/resources"
export COPYFILE_DISABLE=1
pkgbuild --quiet --root "$tmp/root" --scripts "$tmp/scripts-install" --identifier com.colorwindownuke.illustrator \
  --version "$ver" --install-location / --ownership recommended "$tmp/cwn.pkg"
pkgbuild --quiet --nopayload --scripts "$tmp/scripts-uninstall" --identifier com.colorwindownuke.illustrator.uninstall \
  --version "$ver" "$tmp/cwn-uninstall.pkg"

# macOS stamps files created by this process with a protected provenance
# attribute; pkgbuild then lists phantom zero-byte ._AppleDouble entries in the
# package index (BOM). The payload itself is clean, so rebuild the BOM without them.
clean_bom() {
  local pkg=$1 x=$tmp/expand.$RANDOM
  pkgutil --expand "$pkg" "$x"
  lsbom "$x/Bom" | grep -v '/\._' > "$x.list"
  rm "$x/Bom"
  mkbom -i "$x.list" "$x/Bom"
  local n=$(grep -c . "$x.list")
  sed -i '' -E "s/numberOfFiles=\"[0-9]+\"/numberOfFiles=\"$n\"/" "$x/PackageInfo"
  rm "$pkg"
  pkgutil --flatten "$x" "$pkg"
}
clean_bom "$tmp/cwn.pkg"

distribution() {  # $1 title, $2 welcome file, $3 conclusion file or "", $4 pkg id, $5 pkg file
  local conclusion=""
  [[ -n $3 ]] && conclusion="<conclusion file=\"$3\"/>"
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$1</title>
  <welcome file="$2"/>
  $conclusion
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="main"/></choices-outline>
  <choice id="main" visible="false"><pkg-ref id="$4"/></choice>
  <pkg-ref id="$4" version="$ver" onConclusion="none">$5</pkg-ref>
</installer-gui-script>
XML
}
distribution "Color Window Nuke" welcome.txt conclusion.txt com.colorwindownuke.illustrator cwn.pkg > "$tmp/install.xml"
distribution "Uninstall Color Window Nuke" uninstall-welcome.txt "" com.colorwindownuke.illustrator.uninstall cwn-uninstall.pkg > "$tmp/uninstall.xml"

stage=$tmp/stage
mkdir -p "$stage"
sign=()
[[ -n $inst_id ]] && sign=(--sign "$inst_id" --timestamp)
productbuild --quiet --distribution "$tmp/install.xml" --package-path "$tmp" --resources "$tmp/resources" \
  "${sign[@]}" "$stage/Install Color Window Nuke.pkg"
productbuild --quiet --distribution "$tmp/uninstall.xml" --package-path "$tmp" --resources "$tmp/resources" \
  "${sign[@]}" "$stage/Uninstall Color Window Nuke.pkg"
ditto --norsrc --noextattr --noqtn --noacl "$here/Read Me.txt" "$stage/Read Me.txt"

if [[ -n $notary ]]; then
  echo "== notarizing"
  for p in "$stage"/*.pkg; do
    xcrun notarytool submit "$p" --keychain-profile "$notary" --wait
    xcrun stapler staple "$p"
  done
fi

echo "== disk image"
out=$dist/ColorWindowNuke-$ver.dmg
rm -f "$out"
hdiutil create -quiet -volname "Color Window Nuke $ver" -srcfolder "$stage" -fs HFS+ -format UDZO "$out"
[[ -n $notary ]] && { xcrun notarytool submit "$out" --keychain-profile "$notary" --wait; xcrun stapler staple "$out"; }
echo "built $out ($(du -h "$out" | cut -f1), $([[ -n $inst_id ]] && echo signed || echo unsigned))"
