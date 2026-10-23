# Original editable mockups, v0.2

These are **concept screens using invented titles, original immersive illustrations, account states and progress**, not screenshots of a working integration. Text/vector layout and image crops are editable; original JPEG scene derivatives are embedded as data URIs. No Apple UI assets, proprietary covers or paid assets are embedded. Rounded floating capsule shapes describe intended Glass placement, **not compositor refraction**; the executable uses actual native Glass APIs and window controls.

| Source | State |
| --- | --- |
| [Library](screens/library.svg) | Immersive focused-game backdrop, floating capsule, compact Continue Playing and horizontal icon entries |
| [Discover / Browse](screens/discover-browse.svg) | Empty-query editorial art and useful category browse, not fake search results |
| [Discover / Search](screens/discover-search.svg) | Catalog-scoped search with unverified access |
| [Game detail](screens/game-detail.svg) | Four independent facets and exact identity disclosure |
| [Install sheet](screens/install-sheet.svg) | Review download, expansion, staging/reserve and simulated disk space |
| [Downloads](screens/downloads.svg) | Ordered queue; explicit simulated progression |
| [Onboarding / cancellation](screens/onboarding-cancelled.svg) | Sign-in purpose, fixture disclaimer and cancellation recovery |
| [Blocked](screens/blocked.svg) | Purchased does not imply downloadable or supported |
| [Download error](screens/download-error.svg) | Explicit error and simulated retry |

Shared [tokens](tokens.json) define layout, typography and semantic concept colors. `tools/generate_mockups.py` is the committed editable screen source (uses committed JPEG derivatives; enforces <=10 MB per screen):

```sh
python3 tools/generate_mockups.py
```

On macOS, [the native WebKit export helper](../tools/render_mockups.swift) exports all SVGs to PNG without third-party packages:

```sh
swift tools/render_mockups.swift
```

Both commands run from the repository root and only write named design output directories. SVGs are the design authority; PNGs are generated previews. The mock's fixed point sizes are not substitutes for native text metrics, localization or assistive-technology tests. Import SVGs into a vector editor/Figma to edit text, paths or layout.

## Original scene sources

The original 2048 x 1152 harbor/planet/alpine illustrations are authored with CoreGraphics/ImageIO and reproduce without third-party dependencies:

```sh
swift tools/RenderOriginalArt.swift Sources/XodusPreview/Resources/Artwork
```

Secondary desert/forest/ocean vectors are authored by `python3 tools/generate_artwork.py` in `design/artwork`; `swift tools/render_mockups.swift` rasterizes secondary scenes without overwriting primary illustrations. `sh tools/export_mock_assets.sh` creates compact JPEG derivatives; regenerate SVGs/PNG previews afterward. [Resource provenance](../Sources/XodusPreview/Resources/Artwork/PROVENANCE.json) distinguishes the pipelines. These are original stylized placeholders, not real game screenshots; production needs title-specific rights/caching approval.

## Revision and Figma status

[Open latest Library in Figma](https://www.figma.com/design/5iQu716UFImHjRxJkf0t8V?node-id=3-115). **All nine v0.2 imports succeeded** with embedded original JPEGs and fixture disclosure. The coordinating session inspected official Library/Discover renders and confirmed floating capsule placement/immersive composition. Some gradient/rounded-image fidelity is flattened on SVG import; authoritative SVG/PNG/native image resources remain in the repo. Figma is an editable static placement concept, not an exact system-Glass/compositor reproduction, auto-layout/component library or wired prototype.

**v0.1 was not user-approved and is superseded**; original editable SVGs are frozen in [the archive](archive/v0.1/README.md). Multipart names `v0.2-*` distinguish the new frames from old rejected ones.

| Current v0.2 screen | Figma node |
| --- | --- |
| Library | 3:115 |
| Discover / Browse | 3:365 |
| Discover / Search | 3:288 |
| Game detail | 3:248 |
| Install sheet | 3:2 |
| Downloads | 3:70 |
| Onboarding | 3:187 |
| Blocked | 3:208 |
| Download error | 3:321 |

[FigJam UX flow](https://www.figma.com/board/3MejlFaXHkogmJ3J5k79Gw) covers source/freshness/completeness -> access -> PC downloadability -> verified/experimental opt-in/blocked compatibility -> space review -> stage/verify/register -> access/runtime check before play. Failure preserves prior installation and saves. It is an authored proposal, not observed API behavior.
