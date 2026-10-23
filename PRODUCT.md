# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS, implemented with SwiftUI and AppKit. This is intentionally not a website, Electron shell or iOS layout stretched into a window.

## Users

Casual Apple Silicon Mac gamers who legitimately own or subscribe to PC games and want to sign in, see their eligible library, understand whether a title can run, install it and play without Terminal, Wine selection or DLL configuration.

## Product purpose

Make four independent questions understandable: **Do I have access? Can I download this PC package? Does this configuration run it? Is it installed here?** Do not compress these into a green "supported" badge. A catalog entry or play-history record is not proof of ownership.

## Positioning

An original Apple-native, standalone experience over the scoped Xodus management adapter. The mechanism is explicit entitlement, package and runtime evidence, not a broad promise that all Xbox PC games work on Mac. Heroic integration was considered; no shipping new-store plugin API has been established.

## Operating context

Develop and verify native code on the user's Mac over trusted SSH, using isolated public-app tooling. Public source must never include real library captures, account information or private runtime code. Official, separately installed CrossOver is the first-release dependency, not by itself certification of an Xbox-capable, exactly paired gameplay runtime.

## Capabilities and constraints

**19 October direction:** The app name is **Ode to X**. One Microsoft login
must serve the account's library, profile and game authorization. Keep most
product-specific development in isolated modules where practical, but reliable
functionality takes priority over avoiding small upstream integration changes.
The current unified-account source slice supplies account-bound data reads;
runtime integration and live acceptance are unfinished. It is not production
or single-login gameplay readiness.

**User-directed X Ode first-run correction (16 October, source candidate):**
the live window opens a native welcome/sign-in sheet before displaying Library,
Discover, Downloads or cached installations. Current management account status,
not a remembered welcome flag or local game registration, unlocks those surfaces.
Pending, cancelled, expired, failed or disconnected sign-in keeps them hidden;
files, saves and registrations are preserved. Missing app/service pairing disables
sign-in with a concise unavailable explanation. The only dependency handoff in
Welcome is the official CodeWeavers trial page when CrossOver is absent or
unverified; there is no embedded runtime download or installer. Developer setup
banners are no longer part of the main window. Management saved sign-in,
PC-library credentials and the Xbox game-service account are still distinct:
Welcome does not merge their identities or assert ownership/gameplay. Product
display branding is X Ode; existing bundle, executable, Keychain and security
identities are unchanged. This first-run privacy gate supersedes the earlier
anonymous browsing/local-installation entry behavior described below.

**SDD personal-Library slice (9 October, source only):** Your Games is now
access-qualified from the last complete account-held PC collection, never from
installation or public discovery alone. Unverified local installations remain
reachable in a separate native group; their files and saves are not changed.
Personal counts, filters, search, hero and Continue Playing use the same join.
Failed refresh preserves a visibly stale complete snapshot but removes it from
the current Your Games set and disables new downloads. Installed records remain
reachable with Access not verified; confirmed revocation or account mismatch
retires its access.

**M10 account tiers:** the shared model distinguishes current held ownership,
current subscription grants and unverified access. Owned and subscription access
are independent; subscription-held entries never enter the Owned filter.
Saved credentials or a failed/in-flight refresh cannot establish a Free or
Owned tier. Recurring collection entries show Subscription (plan unknown), not
a fabricated PC/Console/Ultimate plan. The game-service licence probe lacks an
identity binding to the PC-library account, so its result is shown separately
and is not merged into that account's tier. Saved probe results are historical
and must be checked again before opening subscription install review.
Fixture coverage lives in `Tests/ManagementChecks/Fixtures/account-tiers.json`,
with controller transition checks in the preview harness. Perks, leaving-soon
dates and subscription expiry remain unavailable without a real source.

The current `gamepass-status` contract is a scoped licence probe, not a complete
subscription/expiry API or an account-bound per-edition access grant. Therefore
Game-Pass-only candidates **cannot currently be admitted to Your Games**. Held
games may also show explicitly public **Game Pass catalog** membership, not
extra account authorization. Partial discovery omits no-title verdicts, filters
on the actual PC-candidate field, retains bounded unconfirmed records and
labels refresh failures. No freshness TTL, paid acquisition or expiry date is
invented. See the exact source acceptance boundary in
[requirements](docs/REQUIREMENTS.md#sdd-lib-source-acceptance).

Discover and detail retain the existing protected **Check Game Pass access**
route for a PC catalog member with active subscription status. This opens the
existing package/compatibility/storage review, not a download or an access
grant. Only successful preflight and explicit confirmation can proceed.
The first SDD candidate removed this working route; the frontend follow-up
restores it without admitting unresolved titles to the personal Library.

Library preserves the incumbent installed-game cards without labeling local files
as ownership or subscription access. Account-held PC games load automatically in
the background; the last complete same-account snapshot stays visible during
refresh and transient failure, and is cleared on account retirement. Discover
remains public browsing. There are no additional refresh controls or management
disclosures. Native Play still requires the matched account/runtime and the
service's actual per-game licensing; installation alone grants no access.
The frozen Collections producer currently returns zero raw records and does not
separately enumerate Game Pass access, so the requested fully account-qualified
Library remains unresolved pending an authoritative per-product source. This is
not an empty-account conclusion. Cover grids top-align artwork regardless of
metadata height.

**Proposed v1:** account connection, entitled PC library, scoped catalog discovery, edition selection, explicit eligibility and compatibility, installation planning, durable downloads/recovery, launch, safe updates/removal and redacted diagnostics.

Player-facing game cards and details prioritize real title information and
actions. They never expose internal test verdicts, test progress, proof paths or
agent notes. Real install/launch progress and errors remain visible; package and
anti-cheat limitations stay concise and actionable.

**Not promised in v1:** party/chat/LFG, follower counts not supplied by Xbox,
Rewards, offers/checkout, cloud saves, cloud gaming, DLC/mod management,
all-PC-title support or arbitrary runtime downloads/removal. Discover does not
claim purchasability or ownership.

**Current parity scope:** Account is a native hub for the Xbox game-service
Profile, real Xbox connection fields, per-title Achievements, cached My Consoles and a
dedicated Engines page. Recent Xbox activity is play history, never an owned
library. Remote Play is an official default-browser handoff to
`https://www.xbox.com/remoteplay`; Xodus does not wake, power, address or stream
from a console. The PC collection currently supplies an active account-held
entitlement but no paid/free acquisition kind, so the app records acquisition
as unknown and never relabels Owned as Purchased. Owned and Game Pass membership
are independent and may appear together.

**Today:** a native development app with a real management client, paired native
authentication, public catalog, account-bound PC Library and a separate
explicit activity scope. Installed Play and game-service sign-in, Install,
Repair and save-preserving Uninstall are independently admitted, installed and
owner-live-accepted in bounded title/flow tests. Discover/owned-first search and
package-support checks are independently admitted, installed and owner-live-accepted
at `7c3c1f0`. Game Pass subscription/shelf, self-contained script paths, Setup
and Stop are admitted and installed at `fee7f5f`. Owner live acceptance is
partial: cached status, Setup, successful Repair and the shelf header were
observed. The user's native login Keychain unlock allowed acceptance to resume;
probe selection and stale Setup readiness corrections are admitted, installed
and owner-live-accepted at `208939c`: Active, all Ready, and no stale setup
banner after Check game sign-in. No unlock is automated. The earlier B6 ACL
approach was rejected because self-signed builds have distinct Keychain
partitions even with a stable certificate requirement. The user selected a
separately installed, byte-frozen authenticated credential broker for the new
three-hour B6 slice. The admitted `2d420d1` implementation uses explicit approval and verified staged
copy migration; a failed old-item deletion retains the new copy with a visible
notice, not an automatic retry. The separately owner-authorized user-present
migration completed with `legacyRetained=false`; an identical reinstallation
and distinct signed non-installed Library review both read through the frozen
broker without an observed Keychain prompt. Review reads never persist refreshed
credentials. These bounded live observations are separate from synthetic tests
and do not guarantee every future replacement or authorize helper upgrades.
No complete owned-view parity or general gameplay certification is
claimed. Exact deployment and real provider evidence are recorded separately
in [native integration](docs/NATIVE-INTEGRATION.md), never inferred from mocks.
An explicit nonshipping `--fixture` mode retains the original demonstration;
its non-durable jobs and invented titles never become live evidence.

**User-decided:** original app code/docs/art use GPL-3.0-only, matching the user's stated Xodus licensing intent without assuming an "or later" grant.

**Shipping truth boundary:** the production compile excludes the offline demo's
views/state/art/resources and development check/export paths. Live screens use
actual public management data and honest native setup/empty/loading/error states,
not promotional synthetic game scenes. Shipping executes only an externally
approved, compiled-pin-bound bundled engine/helper pair; an unpaired repository
build fails closed. This source hardening is not shipping deployment or proven
human authentication. See [controlled admission](docs/SHIPPING-ADMISSION.md).

**User-directed first-release runtime policy (RT-01..04):** official CrossOver
is checked read-only using fixed standard locations and the approved
Apple-anchored CodeWeavers identity. Only verified observation defaults a
new/unset configuration; explicit decoded/selected profiles are preserved.
Missing or unverified CrossOver shows a gameplay prerequisite, without blocking
public browsing or sign-in. GPTK3/GPTK4, standalone/source-built Wine and custom
graphics are Experimental, requiring acknowledgement that resets on relevant
changes. Installation identity does not prove a license, ownership or gameplay.
Engine provenance/version and
graphics backend/provenance/version are independent: Wine 11 plus D3DMetal 4
is a composition, not an older GPTK Wine version. Configuration, installation,
device preflight and per-game verification remain distinct. Prefix generations
must be isolated, without silent reuse/migration/deletion of bottles or saves.
This separate source follow-up does not change the frozen authentication
contract, enable launch, import trial proof or establish redistribution rights.

**Proposed/pending:** macOS 14 deployment baseline; exact supported hardware/storage policy; third-party runtime redistribution; distribution/signing model; source of authoritative ownership and package authorization; subscription expiry behavior; compatibility verification governance. See [decision register](docs/RESEARCH.md).

## Brand commitments

Apple Games for macOS is the actual composition authority, not Xbox. The user
initially requested immersive artwork, floating transparent navigation and
edge-to-edge detail images, then rejected the bespoke rounded menu as non-native.
The latest user direction groups native navigation and compact scoped search
in the system bar, with a separate trailing Account control, no visible app
title and original artwork behind chrome. Real macOS 27 tabs have a segmented
14-26 runtime fallback; SDK 27+ is required to build. System controls, type,
focus and semantic appearance take precedence over hand-rolled pill geometry.
Actual macOS 26+ Glass is used where available, not ordinary material relabelled
as glass. SwiftUI/AppKit remains the native framework; UIKit was not a chosen
rewrite. An older native toolbar is deployed in the pairing recorded in
verification. The current Library-only replacement uses the approved v0.2
Figma layout/flow and Apple Games visual treatment: art under the native
toolbar, large glass hero controls, landscape Continue Playing and portrait
2:3 covers with native segmented filters and fixed-size Sort. Production follows
system appearance; Dark and Light own-window review precedes shipping admission.
Natural artwork-dependent toolbar appearance remains a compositor gate.

The Library grid joins exact installed IDs, the loaded PC collection and active
Game Pass feed evidence without promoting installation into purchase. Owned
means held by the PC-library account; its acquisition kind is currently unknown.
Owned and In Game Pass badges remain independently visible and their filters
overlap. Its saved
PC library loads once on appearance after migration/presence checks; Refresh is
in the toolbar/Command-R and Sign out is in Account. The isolated review uses
broker-read-only loading instead, with Game Pass explicitly not loaded when no
validated discovery snapshot is available. Discover, detail, installation
consent and Downloads remain unchanged pending Library sign-off. Navigation is
Library / Discover / Downloads; Library remains the default. No Apple logos,
proprietary imagery in public source, invented Friends/Arcade or Xbox-green
identity. v0.1 was not approved and is explicitly superseded.

## Evidence on hand

The supplied research findings distinguish known CLI capabilities from unproven inventory, protocol and recovery. The privately viewed Apple Games Home is a reported visual observation; no screenshot or assets are published here. Historical private gameplay reports are not current compatibility verification. All public preview data and artwork are fictional.

## Product principles

1. Evidence before action: no install or play based solely on a successful exit code.
2. Access, package eligibility, compatibility and installation are independent.
3. Native simplicity by default; diagnostics never require a player to become a runtime engineer.
4. Interrupted work is recoverable; updates preserve the last runnable version and saves.
5. Public development never leaks private accounts or runtime material.

## Accessibility and inclusion

Full keyboard operation, VoiceOver names and ordered status announcements, reduced motion/transparency, readable resizing, light/dark appearance, localizable content, explicit offline states and no color-only meaning are production gates. The foundation supplies semantic native controls and a subset of these states; full assistive-technology testing is still a release gate.
