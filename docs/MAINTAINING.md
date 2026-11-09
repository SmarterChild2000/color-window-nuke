# Maintaining Color Window Nuke

## Adding a new Illustrator version

1. Install the new Illustrator from Creative Cloud and open it once.
2. Find its bundle ID and build:
   ```bash
   defaults read "/Applications/Adobe Illustrator <year>/Adobe Illustrator.app/Contents/Info" CFBundleIdentifier
   defaults read "/Applications/Adobe Illustrator <year>/Adobe Illustrator.app/Contents/Info" CFBundleVersion
   ```
3. Add `"<bundle id>/<build>"` to `kVerifiedBuilds` in `plugin/src/ColorWindowNuke.mm`.
4. Rebuild and run the headless tests:
   ```bash
   plugin/build.sh && tests/run_tests.sh
   ```
5. Install it into that Illustrator (`installer/install.sh --only <version>`), restart Illustrator,
   and check:
   - Close Color, then click Stroke/Fill a few times. Color stays closed (a brief pop on the very
     first click is expected).
   - Press `<`. Color stays closed.
   - F6 and Window > Color open the panel normally.
6. Update [COMPATIBILITY.md](COMPATIBILITY.md) and the "Which download do I need?" table in the
   README. Bump the version in `plugin/Info.plist`, add a line to `CHANGELOG.md`, and build the
   release:
   ```bash
   installer/build-release.sh
   gh release create v<version> dist/ColorWindowNuke-<version>.dmg --title "v<version> — Illustrator …" --notes-file <notes>
   ```

If Illustrator changes how the Color panel opens, the plug-in fails safe: it does nothing, or stops
for the session after one ineffective try. Illustrator then simply behaves normally.

## Signing (removes the macOS "can't be opened" step)

1. Join the Apple Developer Program and create **Developer ID Application** and **Developer ID
   Installer** certificates.
2. Run `xcrun notarytool store-credentials <profile>` once.
3. Build with
   `installer/build-release.sh --sign-app "Developer ID Application: …" --sign-installer "Developer ID Installer: …" --notarize <profile>`.

## Never commit

The Adobe Illustrator SDK and its headers. Its license forbids redistributing them, so keep it at
`~/Developer/Adobe Illustrator 2026 SDK`.
