# X Ode

By Working Principle · Beta

A native macOS interface for legitimately entitled Xbox PC games, powered by
the Xodus backend and separately installed runtimes.

**Experimental; not a public release.** Catalog visibility, account access,
package support and successful Mac gameplay are separate facts. A verified app
signature or an installed game folder does not establish entitlement or
compatibility.

## What the UI can do

These are source-backed capabilities, not a claim that every action is accepted
on the newest package. [Launch readiness](docs/LAUNCH-READINESS.md) separates
historical deployments, recovered package receipts and current unknowns.

| Area | Available interface | Important boundary |
| --- | --- | --- |
| Discover / search | Browse PC Game Pass candidates, search Store games, show loaded owned matches first, open details | Public results and artwork do not grant ownership or Mac compatibility; search coverage is partial |
| Account / library | Explicit sign-in, account-bound collections, background access checks for known installed Store IDs, Installed and Continue Playing | Permission does not identify ownership or subscription acquisition; uninstalled account-wide Game Pass enumeration is unresolved |
| Install / downloads | Check support, confirm destination and space, show backend progress, cancel | Requires an entitled supported package and the paired runtime; Install never auto-plays |
| Play / Stop | Launch a registered installed game; request Stop for the tracked title | Current account access and runtime/title-specific qualification still apply; ordinary Quit does not stop gameplay |
| Repair / update / remove | Explicit runtime repair, Check for update / Repair, confirmed Uninstall, separate Remove from list | List removal does not delete files; save preservation needs exact-runtime acceptance |

Library checks known installed products automatically and retains still-valid
access facts while renewing them. Expiry, sign-out and account changes withdraw
permission. Installed records without confirmed access remain separately
manageable; they are not relabelled Owned or Game Pass.

The latest private local candidate has bounded live evidence for 36 installed
products and renewal across the original cache boundary. That is not general
gameplay certification, offline permission or a public distribution approval.
Library scrolling and tab-switch responsiveness are under separate UX and
performance review.

```mermaid
flowchart LR
    UI["X Ode: Discover / Account / Library"] --> Catalog["Public catalog: discovery only"]
    UI --> Access["Account-bound access checks"]
    Access --> Consent["Support check + explicit Install"]
    Consent --> Backend["Paired Xodus backend + reviewed runtime"]
    Backend --> Game["Entitled, supported game"]
    UI --> Registered["Registered installation: Play / Stop"]
    Registered --> Backend
```

### Visual reference, not gameplay evidence

![Historical Library fixture mockup with original fictional game illustrations](https://raw.githubusercontent.com/dragoshont/xodus-macos-app/fac58d6f501c356a0e763d397263e5a0a30b3477/design/previews/library.png)

**Historical fixture mockup, not a current app or game screenshot.** The image
uses fictional titles and original illustrations; its access labels are invented.
It retains the earlier Xodus name. It was inspected for account names, emails and
tokens; none were visible. No live account capture or copyrighted game art is
republished. [Artwork provenance](https://github.com/WorkingPrinciple/xode-ui/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Sources/XodusPreview/Resources/Artwork/PROVENANCE.json).

## Before you try it

New game installations default to `~/Games/Xode`. Saved custom installation
roots and partial-install destinations are retained; this source change does not
move existing games. Discovery also recognizes the legacy `Xodus` library roots.

Use an Apple Silicon Mac. The package and app manifests declare macOS 14 minimum;
that is not fresh-Mac certification across supported operating systems.
Development evidence uses Xcode/macOS SDK 27 or newer and Swift 6.4.
Gameplay needs a matching reviewed Xodus engine/runtime, legitimate game
entitlement and explicit human sign-in/Keychain consent. Official CrossOver,
installed and licensed separately, remains the documented first-release
dependency; other Wine/graphics recipes remain experimental. CrossOver detection
does not verify its license or certify a game.

**Installation:** no public installer is recommended yet. Use only an
independently admitted, source-matched package with rollback preserved; close the
app normally and ensure games and mutations have ended before replacement.
Never force Quit to bypass an installation hold, disable macOS protections, or
replace the credential helper silently. See the [release checklist](docs/LAUNCH-READINESS.md#release-checklist).

### Build the UI source (macOS only)

The Swift app source is included on `main`:

```sh
git clone https://github.com/WorkingPrinciple/xode-ui.git x-ode-source
cd x-ode-source
swift build --product XodusPreview
sh tools/check.sh
```

`XodusPreview` is the retained executable name. Its default is the native live
development shell, not simulated gameplay. The original fixture demonstration
is nonshipping only. Building does not install, sign, launch a game or produce
an admitted release. Shipping packaging requires reviewed engine/provenance
hashes, exact source/tree, explicit signing identity and helper receipts accepted
by [the packager](tools/build_app.sh); do not guess inputs or distribute an
unpaired build. See [controlled pair admission](docs/SHIPPING-ADMISSION.md).

## Reference and limitations

- [Product](PRODUCT.md), [design](DESIGN.md) and [UX flows](docs/UX-FLOWS.md)
- [Architecture](docs/ARCHITECTURE.md) and [backend contract](docs/BACKEND-CONTRACT.md)
- [Native integration](docs/NATIVE-INTEGRATION.md) and [verification](docs/VERIFICATION.md)
- [Runtime providers](docs/RUNTIME-PROVIDERS.md) and [launch readiness](docs/LAUNCH-READINESS.md)

Exact installed-engine selection through the UI and a sanitized resource-bundle
allowlist are not finished. Catalogue projections and private-origin evidence
remain subject to redistribution review; merging source does not clear those
rights. Install/cancel/resume acceptance on the latest candidate remains
incomplete without an eligible uninstalled test target. Broader gameplay,
online multiplayer, signing/notarization and distribution need separate evidence.
Heroic integration, Cuphead/Celeste success and UWP/EAppx gameplay are not launch
claims. Documentation does not hide or disable existing controls.

## What X Ode may ask permission for, and why

macOS asks the first time each one is needed. Windows games run through X Ode, so a prompt a game triggers names X Ode.

| Permission | When and why |
|---|---|
| Local network | X Ode and the games it runs use your local network to find Xbox consoles and for multiplayer features. |
| External drives | When X Ode stores games on an external drive, or a game it runs reads or saves files there. |
| Network drives | When X Ode stores games on a network drive, or a game it runs reads or saves files there. |
| Documents folder | When X Ode stores games in your Documents folder, or a game it runs reads or saves files there. |
| Downloads folder | When X Ode stores games in your Downloads folder, or a game it runs reads or saves files there. |
| Desktop folder | When X Ode stores games on your Desktop, or a game it runs reads or saves files there. |
| Notifications | After a game finishes installing, so X Ode can tell you it's ready to play. Never at launch. |
| Keychain | When X Ode checks or saves your Microsoft sign-in on this Mac. |

To change an answer, use System Settings ▸ Privacy & Security for local network and folders, and System Settings ▸ Notifications for notifications. X Ode also shows an Open System Settings button next to a problem it can fix. Keychain asks separately for each saved sign-in; there's no System Settings switch for it.

In-game voice chat and microphone input aren't supported in this beta. Developer ID–signed releases keep the same app identity, so permissions you already granted and your saved sign-in carry over between them.

## Scope and credits

X Ode builds on [Xodus](https://github.com/xodus-gaming/xodus) and the
[macOS backend fork](https://github.com/WorkingPrinciple/xodus-macos).
Original app source, documentation and mockups are GPL-3.0-only; preserve
[the source license](LICENSE), [NOTICE](NOTICE), [licensing boundaries](docs/LICENSING.md),
upstream notices and corresponding-source obligations when distributing. The
X Ode and Working Principle names and logos aren't licensed by the GPL; see
[TRADEMARKS](TRADEMARKS.md).
CrossOver, games and other third-party components retain their own terms; GPL
does not authorize redistribution of proprietary packages or credentials.

This is an independent project, not affiliated with or endorsed by Microsoft,
Xbox, Apple, CodeWeavers or game publishers. X Ode is the product name shown in
the app (one source: `AppBrand` in `Sources/XodusCore/AppBrand.swift`); bundle
identifiers, executables, module names, preference keys, Keychain identities,
signer requirements and existing Xodus paths are unchanged.

Backend scope and launch boundaries: [coordinator regrouping notes](https://github.com/WorkingPrinciple/xodus-macos/blob/dragoshont-heroic-xbox-integration/docs/xodus/regrouping.md)
and [publication precautions](https://github.com/WorkingPrinciple/xodus-macos/blob/dragoshont-heroic-xbox-integration/docs/xodus/publication.md).
