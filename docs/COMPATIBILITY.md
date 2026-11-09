# Compatibility

Color Window Nuke acts only on the Illustrator builds a release was tested against. On any other
build it stays inactive, and Illustrator behaves normally.

| Illustrator | Version (bundle ID) | Mac | First supported in | Tested |
|---|---|---|---|---|
| Illustrator 2026 | 30.8.2 (`com.adobe.illustrator`) | Apple Silicon | v1.0.0 | Fill/Stroke, `<`, F6 |
| Illustrator 2027 Beta | 31.1.0 (`com.adobe.illustratorBeta`) | Apple Silicon | v1.0.0 | Fill/Stroke, `<`, F6, Window > Color, Appearance, docked drawer |

- **macOS:** 13 or later. Tested on macOS 27.
- **Intel Macs:** not supported. Current Illustrator releases are Apple Silicon only.
- **Language:** Fill/Stroke works in any language. Detecting the panel on the `<` key and
  Appearance paths currently relies on English panel names.

To check your version, choose **Illustrator > About Illustrator** in Illustrator.
