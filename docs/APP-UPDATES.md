# App updates (REQ-143)

SPDX-License-Identifier: GPL-3.0-only

## What exists

A provider-neutral update layer in `Sources/XodusManagement/AppUpdate.swift` and a
Sparkle 2.10.1 adapter in `Sources/OdeUpdates/SparkleUpdateDriver.swift`.
The owner approved Sparkle (COR-298), GitHub hosting and Developer ID signing
(COR-299), and supplied the public EdDSA key after generating it in Keychain
(COR-300). `SUFeedURL` is still absent: Settings > General > Updates says
"No update feed configured", the toolbar shows nothing, and Sparkle is never
constructed or started. The public key alone does not activate the updater.

| Part | Behaviour |
| --- | --- |
| `UpdateDriver` | `check(etag:)` and `relaunchToInstall(_:)` only. It has no way to terminate a process. |
| `AppUpdateSchedule` | At most one scheduled check per 24 h plus up to 1 h jitter; back-off 1, 2, 4 days capped at 7; skips when offline, in Low Data Mode or in Low Power Mode. |
| `AppUpdatePreferences` | Every key is `Xodus.update.*`: `autoCheck` (default on), `skippedVersion`, `remindUntil`, `nextCheck`, `lastCheck`, `failures`, `etag`, `available`. |
| `AppUpdateController` | Check, Check Now, Skip This Version, Remind Me Later, quiet scheduled failures, and `installWhenIdle()` which defers while a game runs or an install or operation is active. |
| Toolbar | `AppUpdateToolbarIndicator` (`arrow.down.app`) beside the avatar, only for available, downloading, ready or waiting. A skipped or snoozed version is hidden; Check Now shows it again. |

Checks: `Tests/ManagementChecks/AppUpdateChecks.swift` covers UPD-02, 03, 04, 07,
08 and 10 with a fake driver and an injected clock.
`swift test --filter SparkleUpdateDriverTests` covers no-feed startup, fake
sessions, one-shot idle relaunch and Sparkle's build-number version comparison.

## Not built (owner decisions)

UPD-01 (published feed), UPD-05 (Download UI and real archive),
UPD-06 (end-to-end signature/Team ID/notarization proof), and UPD-09
(before/after data preservation proof) are not delivered by this source-only
adapter. No download or installation can be initiated from this slice. Feed
activation, channel and publication remain release decisions; L8 owns bundle
embedding, signing and approved notarization. This lane does not sign, notarize,
tag or publish anything.

## Sparkle adapter

`SparkleUpdateDriver: UpdateDriver` is wired into `AppState.appUpdate`.
The pinned API contracts are the [2.10.1 headers](https://github.com/sparkle-project/Sparkle/tree/2.10.1/Sparkle).

- `isConfigured` requires a nonempty HTTPS `SUFeedURL` without embedded
  credentials and a nonempty `SUPublicEDKey` in the bundle's Info.plist.
- `check(etag:)` uses `SPUUpdater.checkForUpdateInformation()` and completes
  on `didFinishUpdateCycleFor`; it makes no second HTTP request. Sparkle owns
  HTTP caching, so this adapter returns no fabricated ETag/304. The provider
  protocol's ETag support remains available to other drivers.
- `SUAppcastItem.displayVersionString` is user-visible; `versionString` is
  the monotonic `CFBundleVersion` used for comparison. Thus two beta builds
  with the same marketing version can still update.
- Use `SPUStandardUserDriver` with `supportsGentleScheduledUpdateReminders`
  and `standardUserDriverShouldHandleShowingScheduledUpdate` returning false.
  Information-only checks have no Sparkle alert; the toolbar and Settings
  represent availability. A future explicit Download action must start the
  standard user-driver session.
- Keep Sparkle's own scheduler off (`SUEnableAutomaticChecks` false, `automaticallyChecksForUpdates` false) so the layer above stays the single schedule and Low Data and Low Power rules apply.
- `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` is confirmed
  in 2.10.1 `SPUUpdaterDelegate.h`. It retains a one-shot continuation and
  notifies the controller. `relaunchToInstall(_:)` invokes it only after
  both controller and adapter check idle. Aborted sessions discard it.
  Sparkle documents that this delegate is not called on every installation
  path (for example a previously postponed on-quit install): Download UI
  activation must qualify those paths against the app's termination gate
  before any feed is enabled.
- Keep `SUEnableSystemProfiling` off.
- The bundle ID, Team ID (M62Z4M5EUY) and Keychain access groups must stay stable across updates. A SwiftPM executable cannot self-update; this needs the real signed `.app` from the build lane.

## Owner-run key lookup

The key already exists in the owner's login Keychain. Do not generate another
one, read private-key data, export it or put it in a file/environment variable.
`scripts/sparkle-setup-key.sh /path/to/Sparkle-2.10.1/bin` now only invokes
`generate_keys -p`, which prints the existing **public** key and fails if
absent. It never falls back to generation. This lane does not run it.

## Dry-run release plan (COR-299)

`scripts/sparkle-prepare-release.sh /path/to/signed.app /path/to/Sparkle-2.10.1/bin /new/output/directory v0.2.0-beta.1`
prints, but never executes, archive, `sign_update` and `generate_appcast`
commands. The tools use the existing default Keychain account (`ed25519`);
no private-key arguments are supported. It selects no beta channel and
disables delta generation initially. The proposed feed exists **only in
release tooling**, not the shipped Info.plist:

`https://github.com/WorkingPrinciple/xode-ui/releases/latest/download/appcast.xml`

GitHub's `latest` route does not select prereleases. Before enabling this URL,
the owner must choose stable-only releases or a dedicated prerelease feed;
do not silently change the channel or assume a beta release is reachable.
Archive URLs use `/releases/download/<tag>/...`, not the moving `latest` URL.
No execution, tagging, upload, release creation or publication is implemented.

## Build-lane handoff (not performed here)

Use the framework from the checksum-bound SwiftPM artifact. Embed its complete
`Sparkle.framework` at `Contents/Frameworks`, preserving the versioned framework
layout and XPC services. Ensure the main executable's runtime search path
includes `@executable_path/../Frameworks`.
Follow [Sparkle's signing instructions](https://sparkle-project.org/documentation/sandboxing/)
for the exact 2.10.1 contents: sign nested executable helpers and XPC bundles
inside-out, then the framework, then the app, with
`Developer ID Application: Dragos Hont (M62Z4M5EUY)`, hardened runtime and
timestamps. Keep library validation enabled; do not add
`com.apple.security.cs.disable-library-validation` as a workaround. Do not
re-sign using `codesign --deep`.

The current packaging gate rejects framework symlinks and unmapped code.
L8 must add exact framework/helper identities, contained-symlink validation,
notice copying (`ThirdParty/Sparkle/LICENSE`) and corresponding-source
inventory entries before a distributable candidate can pass. The source
manifest in `ThirdParty/components.json` is not that final signed inventory.
Do not disable the gate. Verify nested signatures, Gatekeeper and the
owner-approved notarization before generating any distributable archive.

## Licence check (against LICENSING.md)

Sparkle 2.10.1 and its bundled components retain MIT, BSD-2-Clause and Zlib
grants, compatible with the original app's GPL-3.0-only grant. The full,
unmodified upstream combined text is `ThirdParty/Sparkle/LICENSE`; source,
version, artifact checksum and component entries are in
`ThirdParty/components.json`. `NOTICE` and `LICENSING.md` identify the new
dependency. Final bundle inventory and rights review remain packaging work,
not a blanket distribution clearance.
