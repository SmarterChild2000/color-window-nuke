#!/bin/zsh
# Headless test suite: unit tests + read-only static compatibility check.
set -u
here=${0:A:h}
root=${here:h}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
rc=0

echo "== IntentModel unit tests"
clang++ -std=c++17 -Wall -Wextra -Werror -O1 -o "$out/test_intent" "$here/test_intent.cpp" && "$out/test_intent" || rc=1

if [[ -f $root/tools/aicompat.py ]]; then
  echo "== Static compatibility check (read-only)"
  python3 -I "$root/tools/aicompat.py" || rc=1
fi

# Same SDK lookup as plugin/build.sh: official SDK if present, else the private dev shim.
sdk=${CWN_SDK:-"$HOME/Developer/Adobe Illustrator 2026 SDK"}
if [[ -f $sdk/illustratorapi/illustrator/AINotifier.h ]]; then
  api=$sdk/illustratorapi
  mock_incs=(-I"$root/plugin/src" -isystem "$api/illustrator" -isystem "$api/illustrator/actions" -isystem "$api/pica_sp" -isystem "$api/ate" -DPC_OFFICIAL_SDK=1)
else
  mock_incs=(-I"$root/plugin/sdk-shim")
fi

if [[ -d "$root/build/ColorWindowNuke.aip" ]]; then
  echo "== Built plug-in sanity"
  bin="$root/build/ColorWindowNuke.aip/Contents/MacOS/ColorWindowNuke"
  lipo -archs "$bin"
  nm -gU "$bin" | grep -q ' _PluginMain$' && echo "PluginMain exported" || { echo "FAIL: PluginMain not exported"; rc=1; }
  python3 -I "$root/plugin/tools/mkpipl.py" --verify "$root/build/ColorWindowNuke.aip/Contents/Resources/pipl/plugin.pipl" || rc=1
  codesign --verify --verbose=1 "$root/build/ColorWindowNuke.aip" || rc=1

  echo "== Mock-host integration test (compiled plug-in, background process, no UI)"
  xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wno-unused-parameter -Wno-four-char-constants \
    "${mock_incs[@]}" -framework Cocoa -o "$out/mockhost" "$here/mockhost.mm" \
    && "$out/mockhost" "$root/build/ColorWindowNuke.aip" || rc=1
  echo "== Mock-host integration test with release defaults (no logging)"
  CWN_MOCK_QUIET=1 "$out/mockhost" "$root/build/ColorWindowNuke.aip" | grep -E 'no log|passed|FAIL' || rc=1
  echo "== Mock-host integration test with the debug recorder on"
  CWN_MOCK_DEBUG=1 "$out/mockhost" "$root/build/ColorWindowNuke.aip" | grep -E 'recorder|passed|FAIL' || rc=1

  echo "== Release installer scripts (throwaway home folder)"
  H=$(mktemp -d); A="$H/Library/Application Support/Adobe"
  mkdir -p "$A/Adobe Illustrator 30/en_US/Plug-ins/Other.aip" "$A/Adobe Illustrator 29/en_US/Plug-ins" \
           "$A/Adobe Illustrator 31.1.0 Beta Settings/en_US/Plug-ins/ColorWindowNuke.aip/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.someone.else" \
    "$A/Adobe Illustrator 31.1.0 Beta Settings/en_US/Plug-ins/ColorWindowNuke.aip/Contents/Info.plist" >/dev/null
  CWN_TEST_HOME=$H CWN_TEST_SRC=$root/build/ColorWindowNuke.aip zsh "$root/installer/pkg/install/postinstall" >/dev/null
  CWN_TEST_HOME=$H CWN_TEST_SRC=$root/build/ColorWindowNuke.aip zsh "$root/installer/pkg/install/postinstall" >/dev/null
  check() { if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; rc=1; fi; }
  ours="$A/Adobe Illustrator 30/en_US/Plug-ins/ColorWindowNuke.aip"
  [[ -d "/Applications/Adobe Illustrator 2026" ]] && check 'cmp -s "$root/build/ColorWindowNuke.aip/Contents/MacOS/ColorWindowNuke" "$ours/Contents/MacOS/ColorWindowNuke"' "installs into an installed Illustrator"
  check '[[ ! -e "$A/Adobe Illustrator 29/en_US/Plug-ins/ColorWindowNuke.aip" ]]' "skips settings folders of uninstalled Illustrators"
  check '[[ $(defaults read "$A/Adobe Illustrator 31.1.0 Beta Settings/en_US/Plug-ins/ColorWindowNuke.aip/Contents/Info" CFBundleIdentifier) == com.someone.else ]]' "never overwrites a different file with the same name"
  CWN_TEST_HOME=$H zsh "$root/installer/pkg/uninstall/postinstall" >/dev/null
  check '[[ ! -e "$ours" ]]' "uninstall removes our plug-in"
  check '[[ -d "$A/Adobe Illustrator 30/en_US/Plug-ins/Other.aip" ]]' "uninstall leaves other plug-ins alone"
  check '[[ -d "$A/Adobe Illustrator 31.1.0 Beta Settings/en_US/Plug-ins/ColorWindowNuke.aip" ]]' "uninstall leaves the same-name file alone"
  check '[[ ! -e "$H/Library/Application Support/ColorWindowNuke" ]]' "uninstall removes its own state folder"
  rm -rf "$H"
fi
exit $rc
