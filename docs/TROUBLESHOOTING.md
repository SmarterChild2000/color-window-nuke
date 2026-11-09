# Troubleshooting

| Problem | What to do |
|---|---|
| The Color panel still pops open | Check that your Illustrator version is in [COMPATIBILITY.md](COMPATIBILITY.md). On other versions the plug-in stays inactive. Restart Illustrator after installing. |
| "Plugin issues detected" when Illustrator starts | Uninstall and reinstall from the latest release, then [open an issue](../../../issues) with your Illustrator version. |
| The installer "can't be opened" | System Settings > Privacy & Security > **Open Anyway**, then run it again. |
| Nothing was installed | Open each Illustrator version once (so its Plug-ins folder exists), quit it, and run the installer again. |
| A brief flash on the first Fill/Stroke click | Expected once per launch, while Illustrator builds the panel. |
| Docked icon: Color needs two clicks to open | Expected after a hidden pop-out. Try Preferences > User Interface > Auto-Collapse Iconic Panels. |
| I want Illustrator's normal behaviour back | Run **Uninstall Color Window Nuke** and restart Illustrator. |

**Reporting a problem:** please include your Illustrator version (Illustrator > About Illustrator),
your macOS version, and whether the Color panel is floating or docked. For a detailed log:

```bash
defaults write com.colorwindownuke.illustrator logging -bool true
```

Restart Illustrator, reproduce the problem, and attach the newest file from
`~/Library/Logs/ColorWindowNuke/`. It contains timings and window types, never artwork or keystrokes.
Turn it off again with `defaults delete com.colorwindownuke.illustrator logging`.
