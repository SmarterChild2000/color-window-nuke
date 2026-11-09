# Color Window Nuke for Adobe Illustrator

**Stop Illustrator's Color panel from popping open.**

Click the Fill or Stroke swatch in Illustrator and the Color panel jumps open, even after you closed
it. Designers have [asked Adobe to fix this since 2018](https://illustrator.uservoice.com/forums/333657-illustrator-desktop-feature-requests/suggestions/33877456-the-color-panel-pops-up-when-you-click-on-stroke-f).
Color Window Nuke is a small, free Illustrator plug-in that stops it. You can still open the Color
panel yourself any time with **Window > Color** or **F6**, and it behaves normally.

## Download

Get the latest `.dmg` from **[Releases](../../releases)**, open it, and double-click
**Install Color Window Nuke**. Then restart Illustrator. There are no settings.

### Which download do I need?

| Your Illustrator | Download |
|---|---|
| Illustrator 2026 (30.8.2) | [v1.0.0](../../releases/tag/v1.0.0) |
| Illustrator 2027 Beta (31.1) | [v1.0.0](../../releases/tag/v1.0.0) |

Not sure which version you have? In Illustrator choose **Illustrator > About Illustrator**.
On versions not listed here the plug-in stays inactive, and Illustrator behaves normally.
Requires an Apple Silicon Mac.

> **macOS security note:** these downloads are not signed by an Apple-registered developer yet,
> so macOS may say the installer "can't be opened". Click **Done**, then go to
> **System Settings > Privacy & Security** and click **Open Anyway**, and run it again.

## What it fixes

- Clicking **Fill / Stroke** in the toolbar no longer opens the Color panel.
- The **`<`** key and the **Appearance** panel no longer open it either.
- If your Color panel is **docked as a collapsed icon**, the pop-out is hidden too.

### Good to know

- The very first Fill/Stroke click after opening Illustrator may show the panel for a split second.
  Every click after that is clean.
- Docked as a collapsed icon: after a hidden pop-out, the icon stays highlighted and opening Color
  takes two clicks on it. Turning on Illustrator's *Preferences > User Interface > Auto-Collapse
  Iconic Panels* may help.
- Docked as an expanded tab (for example behind Color Guide): Illustrator still brings the Color tab
  forward. A plug-in has no way to undo that.

## Remove it

Run **Uninstall Color Window Nuke** from the download and restart Illustrator. Or delete
`ColorWindowNuke.aip` from
`~/Library/Application Support/Adobe/Adobe Illustrator <version>/<language>/Plug-ins`.

## Privacy

No internet access, no accounts, no tracking. It never reads your artwork or records what you type.

## How it works

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). In short: when the Color panel appears without
you asking for it, the plug-in makes it transparent before the screen updates, then closes it through
Adobe's own public "toggle Color panel" plug-in call, the same thing Window > Color does.

## Building from source

You need Xcode and the official **Adobe Illustrator SDK**, which you download from Adobe
(<https://developer.adobe.com/console>). The SDK can't be redistributed, so it isn't in this
repository. Put it at `~/Developer/Adobe Illustrator 2026 SDK`, or pass `--sdk <path>`.

```bash
plugin/build.sh            # builds build/ColorWindowNuke.aip
tests/run_tests.sh         # headless tests: logic, simulated Illustrator, installer scripts
installer/build-release.sh # builds dist/ColorWindowNuke-<version>.dmg
```

See [docs/MAINTAINING.md](docs/MAINTAINING.md) for adding a new Illustrator version.

## License

MIT, see [LICENSE](LICENSE). This project is independent and not affiliated with or endorsed by
Adobe. "Adobe" and "Illustrator" are trademarks of Adobe Inc.
