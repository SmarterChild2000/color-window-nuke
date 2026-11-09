# How Color Window Nuke works

## The behaviour it changes

When you click the inactive Fill or Stroke swatch in Illustrator's toolbar, Illustrator shows the
Color panel and then switches Fill/Stroke. The panel appears before any plug-in is told about the
click, and Illustrator offers no setting or plug-in call to stop it from opening. The `<` key and the
Appearance panel can open it the same way.

So Color Window Nuke can't stop Illustrator from *trying* to open the panel. It makes sure you never
see it, and closes it again the official way.

## What it does, step by step

1. **Notice the input.** The plug-in watches Illustrator's own mouse clicks and key presses, inside
   Illustrator only. It never reads which key you pressed, and it needs no Accessibility permission.
2. **Notice the Color panel appearing.** It listens to Illustrator's public plug-in notifications
   ("Fill/Stroke changed", "art properties changed"). When one arrives during your click, it checks
   whether a floating panel window just appeared. It recognises the Color panel from the description
   Illustrator publishes for screen readers (VoiceOver), such as its "Color" tab and color spectrum.
3. **Hide it instantly.** It sets that window to fully transparent right away, well before the screen
   updates. So there's nothing to see.
4. **Close it properly.** A moment later, in the same moment of processing, it calls
   `AIPaintStyleSuite::ToggleColorDialog()` from Adobe's public plug-in SDK. That's the same thing
   **Window > Color** does, so Illustrator's own state stays correct. Then it restores the window's
   normal look, so the panel looks normal the next time you open it.
5. **Check.** If the window didn't go away, the plug-in stops acting for the rest of that session
   instead of retrying.

## What it never touches

- Opening the panel **yourself**: Window > Color, F6 (or your shortcut), any menu command, or a
  workspace switch. None of these are "unwanted", so they're left alone.
- A Color panel you already have open. Nothing new appears, so there's nothing to do.
- Other panels such as Gradient or Swatches, and pop-up menus.
- Illustrator's files, preferences, workspaces, shortcuts, and your documents.

## Docked as a collapsed icon

If Color lives in a dock collapsed to icons, Illustrator pops the whole group out as a side "drawer".
There's no supported way to tuck a drawer back into its icon, and closing the panel would remove it
from your dock. So the plug-in hides the drawer window instead (again invisibly) and never closes the
panel. Illustrator still believes the drawer is open, which is why the icon stays highlighted and the
next click on it closes the invisible drawer.

## Safety rules

- It acts only on Illustrator builds it was tested against. On any other build it stays inactive.
- When it's unsure (zero or several new windows, an unrecognised window), it does nothing, so
  Illustrator behaves normally.
- If a hidden drawer is shown again by Illustrator, drawer hiding stops for that session.
- It writes no files except, if you turn it on for troubleshooting, a log in
  `~/Library/Logs/ColorWindowNuke`.

## Optional settings (troubleshooting only)

The plug-in needs no settings. For troubleshooting:

```bash
defaults write com.colorwindownuke.illustrator mode off           # inactive (diagnose = observe only)
defaults write com.colorwindownuke.illustrator experimentalDrawer -bool false   # leave docked drawers alone
defaults write com.colorwindownuke.illustrator logging -bool true # write a log
defaults delete com.colorwindownuke.illustrator                   # back to defaults
```
