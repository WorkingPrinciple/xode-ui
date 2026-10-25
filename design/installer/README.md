# Installer artwork

`dmg-background.png` (660×400, 72 dpi) and `dmg-background@2x.png` (1320×800, 144 dpi) are the X Ode
disk-image background. They're original artwork: the X mark comes from `Sources/XodusCore/XOdeMark.swift`, and
the gradient, arrow and caption are drawn in code by `RenderDMGBackground.swift`. No third-party images or fonts
are embedded; text uses the macOS system font at render time. Licensed GPL-3.0-only like the rest of the
repository; the X Ode name and mark are covered by [TRADEMARKS](../../TRADEMARKS.md).

Regenerate:

```sh
swiftc -parse-as-library Sources/XodusCore/XOdeMark.swift design/installer/RenderDMGBackground.swift -o /tmp/RenderDMGBackground
/tmp/RenderDMGBackground design/installer
```

Finder layout for the disk image (window 660×400 points, icon size 128): X Ode.app centred at (165, 190), the
Applications alias at (495, 190). Combine both scales for Finder with
`tiffutil -cathidpicheck dmg-background.png dmg-background@2x.png -out background.tiff`.
The background is light, so icon labels read best with Finder's light text; Finder doesn't let a disk image set
label colour.
