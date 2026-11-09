#!/bin/zsh
# Remove everything Color Window Nuke installed, using the install manifest.
# Only paths that end in ColorWindowNuke.aip, or our own ColorWindowNuke state
# folder, are ever removed. Illustrator itself is never modified.
#
#   uninstall.sh [--dry-run] [--purge-logs]
set -euo pipefail
dry=0 purge=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1;; --purge-logs) purge=1;;
    *) echo "unknown option $a" >&2; exit 2;;
  esac
done
state=~/Library/Application\ Support/ColorWindowNuke
manifest=$state/install-manifest.txt
run() { if (( dry )); then echo "would remove: ${@[-1]}"; else "$@"; fi; }
ours() { [[ $(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null) == com.colorwindownuke.illustrator.plugin ]]; }

if [[ -f $manifest ]]; then
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    if [[ $p == */ColorWindowNuke.aip && -d $p ]] && ours "$p"; then run rm -rf -- "$p"
    elif [[ $p != "$state" ]]; then echo "skip unexpected manifest entry: $p"
    fi
  done < "$manifest"
fi
# Safety net for copies installed by hand.
for p in ~/Library/Application\ Support/Adobe/Adobe\ Illustrator*/*/Plug-ins/ColorWindowNuke.aip(N/); do
  ours "$p" && run rm -rf -- "$p"
done
if (( dry )); then
  echo "would delete defaults domain com.colorwindownuke.illustrator"
else
  defaults delete com.colorwindownuke.illustrator 2>/dev/null || true
fi
(( purge )) && run rm -rf -- ~/Library/Logs/ColorWindowNuke
run rm -rf -- "$state"
if (( dry )); then echo "(dry run: nothing changed)"
else echo "Color Window Nuke removed. Restart Illustrator to unload it; Illustrator returns to its native behaviour."; fi
