# App updates (REQ-143)

SPDX-License-Identifier: GPL-3.0-only

## What exists

A provider-neutral update layer in `Sources/XodusManagement/AppUpdate.swift` with no external dependency and no network provider. The shipped driver is `UnconfiguredUpdateDriver`, so Settings > General > Updates says "No update feed configured", the toolbar shows nothing, and no request is ever made.

| Part | Behaviour |
| --- | --- |
| `UpdateDriver` | `check(etag:)` and `relaunchToInstall(_:)` only. It has no way to terminate a process. |
| `AppUpdateSchedule` | At most one scheduled check per 24 h plus up to 1 h jitter; back-off 1, 2, 4 days capped at 7; skips when offline, in Low Data Mode or in Low Power Mode. |
| `AppUpdatePreferences` | Every key is `Xodus.update.*`: `autoCheck` (default on), `skippedVersion`, `remindUntil`, `nextCheck`, `lastCheck`, `failures`, `etag`, `available`. |
| `AppUpdateController` | Check, Check Now, Skip This Version, Remind Me Later, quiet scheduled failures, and `installWhenIdle()` which defers while a game runs or an install or operation is active. |
| Toolbar | `AppUpdateToolbarIndicator` (`arrow.down.app`) beside the avatar, only for available, downloading, ready or waiting. A skipped or snoozed version is hidden; Check Now shows it again. |

Checks: `Tests/ManagementChecks/AppUpdateChecks.swift` covers UPD-02, 03, 04, 07, 08 and 10 with a fake driver and an injected clock.

## Not built (owner decisions)

UPD-01 (signed feed), UPD-05 (download), UPD-06 (signature, Team ID and notarization verification) and UPD-09 (data preservation proof) wait on the owner: dependency, EdDSA key, hosting, channel, signing and notarization. Nothing here publishes, tags, signs or notarizes anything.

## Sparkle adapter (design note only)

If the owner approves Sparkle 2, add `SparkleUpdateDriver: UpdateDriver` in a new file and swap it into `AppState.appUpdate`; nothing else changes.

- `isConfigured` is true only when `SUFeedURL` and `SUPublicEDKey` exist in the bundle's Info.plist.
- `check(etag:)` maps to a background `SPUUpdater.checkForUpdateInformation()`; map `SUAppcastItem` to `AppUpdateInfo` and `SPUUpdaterDelegate` errors to `AppUpdateError`.
- Use `SPUStandardUserDriver` with gentle reminders, so Sparkle never opens its own window for a scheduled check. Our toolbar badge and Settings own the UI.
- Keep Sparkle's own scheduler off (`SUEnableAutomaticChecks` false, `automaticallyChecksForUpdates` false) so the layer above stays the single schedule and Low Data and Low Power rules apply.
- `relaunchToInstall(_:)` calls the postpone-relaunch continuation only when `AppUpdateController` reports idle. The delegate method `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` must be confirmed against the Sparkle version adopted.
- Keep `SUEnableSystemProfiling` off.
- The bundle ID, Team ID (M62Z4M5EUY) and Keychain access groups must stay stable across updates. A SwiftPM executable cannot self-update; this needs the real signed `.app` from the build lane.

## Licence check (against LICENSING.md)

Sparkle 2 is under an MIT-style licence (copyright Andy Matuschak and other named contributors) and bundles components under compatible permissive licences. MIT is GPL-3.0 compatible, so the app could link and ship Sparkle under GPL-3.0-only. This is not a legal determination, which LICENSING.md reserves for the pre-release review. Before shipping, add Sparkle and its bundled component notices to the component, version, licence, notice and source manifest that LICENSING.md already requires. Sparkle would be the first external dependency.
