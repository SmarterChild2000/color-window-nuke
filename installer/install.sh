#!/bin/zsh
# Install Color Window Nuke into the per-user Plug-ins folder of each installed
# Illustrator. Never touches /Applications, Adobe binaries, workspaces, or
# Adobe preferences. Every created path is recorded in the manifest.
#
#   install.sh [--dry-run] [--aip path/to/ColorWindowNuke.aip] [--only <bundle-version>]
set -euo pipefail
here=${0:A:h}
aip=${here:h}/build/ColorWindowNuke.aip
dry=0 only=""
while (( $# )); do
  case $1 in
    --dry-run) dry=1; shift;;
    --aip) aip=$2; shift 2;;
    --only) only=$2; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ -d $aip ]] || { echo "ColorWindowNuke.aip not found at $aip (run plugin/build.sh first)" >&2; exit 1; }

state=~/Library/Application\ Support/ColorWindowNuke
manifest=$state/install-manifest.txt
support=~/Library/Application\ Support/Adobe
run() { if (( dry )); then echo "would: $*"; else "$@"; fi; }

installed=0
for app in /Applications/Adobe\ Illustrator*/Adobe\ Illustrator.app(N); do
  id=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  ver=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
  [[ -n $only && $ver != $only ]] && continue
  case $id in
    com.adobe.illustratorBeta) settings="Adobe Illustrator $ver Beta Settings";;
    com.adobe.illustrator)     settings="Adobe Illustrator ${ver%%.*}";;
    *) echo "skip $app (unknown bundle id $id)"; continue;;
  esac
  for plugins in "$support/$settings"/*/Plug-ins(N/); do
    dest=$plugins/ColorWindowNuke.aip
    echo "Illustrator $ver ($id) -> $dest"
    if [[ -e $dest && $(defaults read "$dest/Contents/Info" CFBundleIdentifier 2>/dev/null) != com.colorwindownuke.illustrator.plugin ]]; then
      echo "  skipped: a different file named ColorWindowNuke.aip is already there"
      continue
    fi
    if (( ! dry )); then
      mkdir -p "$state"
      staging=$(mktemp -d "$plugins/.colorwindownuke.XXXXXX")  # never clobbers an existing name
      ditto "$aip" "$staging/ColorWindowNuke.aip"
      rm -rf "$dest"
      mv "$staging/ColorWindowNuke.aip" "$dest"
      rmdir "$staging"
      grep -qxF "$dest" "$manifest" 2>/dev/null || print -r -- "$dest" >> "$manifest"
    fi
    installed=$((installed + 1))
  done
done

if (( installed == 0 )); then
  echo "No matching Illustrator user Plug-ins folder found. Launch Illustrator once, then retry." >&2
  exit 1
fi
(( dry )) && { echo "(dry run: nothing changed)"; exit 0; }
print -r -- "$state" >> "$manifest"
sort -u -o "$manifest" "$manifest"
cp "$here/uninstall.sh" "$state/uninstall.sh" && chmod +x "$state/uninstall.sh"
echo
echo "Installed. The plug-in starts in diagnose mode (observes only, changes nothing)."
echo "Restart Illustrator yourself when convenient; this script never quits it."
echo "Manifest: $manifest"
echo "Uninstall: \"$state/uninstall.sh\""
