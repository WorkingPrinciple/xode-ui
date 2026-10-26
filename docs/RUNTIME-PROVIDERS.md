# Runtime provider configuration v1

## Engine management source candidate (REQ-79/80)

Settings now puts **Calimocho** and **CrossOver** first as provider choices to
understand and acquire, not two simultaneous effective defaults. CrossOver's
existing publisher-signature check reports observed version/build/location.
Its Get action opens the [official CodeWeavers portal](https://www.codeweavers.com/crossover/download);
Ode does not download, redistribute, purchase or accept a licence.
Calimocho's [official source](https://github.com/dragoshont/calimocho) and
published [0.1120.4.4 release](https://github.com/WorkingPrinciple/calimocho/releases/tag/engine-0.1120.4.4)
are guidance for the pinned engine. A source checkout or a Wine-looking
filename never means installed.

Registered engines are read locally from `Xodus.lifecycle.registry`. All
records remain visible, including missing executables, failed/pending smoke
tests and unsupported kinds. Versions/source URLs are explicitly declarations.
Smoke tested means a local record reports pass and the executable is present;
only the launch service verifies the complete registered artifacts. No provider
row grants whole-provider game qualification. Refresh retires stale observations
on errors and offers retry. Choosing a registry performs no installation.

For account-bound native launches, `Xodus.lifecycle.engine.crossover` and
`Xodus.lifecycle.engine.standaloneWine` select exact records of the matching
kind. A CrossOver preference cannot silently point at generic free Wine.
The existing optional `Xodus.defaultEngine` and per-game `engineOverride` remain
in use. Pinned title recipes retain their exact engine/graphics binding; their
existing precedence is not replaced by these preferences. Unpinned per-game
choices override the default; a missing explicit record refuses launch.
Legacy imported-game executable/bottle registrations remain separate and are
labelled accordingly. No prefix, bottle or save is migrated by Settings.

The separate, account-free **source-only** `engine-inspect` v1 consumer matches
producer `ce6e6d56c880698303afdc587f7f65f09e284849`:
`docs/contracts/engine-inspect-v1.schema.json` and `docs/LIFECYCLE-CLI.md` in the
private backend repository. It is not a management operation or runtime-plan
capability. `engine-inspect --contract-version 1` must explicitly advertise
`engineAdmissionV1` before a registry inspection is attempted. The installed
CLI3121 does not implement it and is not replaced by this work.

An optional schema1 declaration
`"provider":{"id":"calimocho","contract_version":1}` is **untrusted**.
Only the supporting backend's independently reviewed admission manifest and
complete artifact validation can return `admittedProvider:"calimocho"`.
The production manifest is currently empty: there is no production-admitted
Calimocho selection claimed here. A published release asset does not itself
establish backend admission. Generic records, including existing source-built
Wine records without a declaration, stay Wine.
No substring heuristic, self-trusted manifest or app-only allowlist is used.

A successful admitted selection persists the registry path and exact projection
(registry SHA256, unique engine name, Wine/server SHA256, provider admission).
The app binds to the bytes it actually decoded, re-inspects with the **actual
launch executable and its paired identity** before lifecycle side effects, then
passes `--expected-registry-sha256` to the supporting backend's shared launch
validator. Stale/malformed tuples, capability failures and changed identities
refuse launch; there is no fallback to CLI3121 or another engine. The inspector
bounds stdout/stderr, deadline, cancellation and owned-child cleanup. These
source checks do not constitute new-CLI delivery or Calimocho game acceptance.

For optional source integration coverage, set
`XODUS_ENGINE_INSPECTION_TEST_BACKEND` to an explicitly approved, pinned source
CLI executable when running `XodusPreview --live-check`. The consumer probes
that executable and inspects only owned neutral generic-Wine and unadmitted
Calimocho fixtures; it never launches their artifacts. The normal suite uses
synthetic CLI scripts, including an unsupported old-CLI fixture. Neither mode
establishes installed delivery or production admission.

### Research and native proposal

Reviewed 24 October 2026 against Heroic main
[`509a34feea8541b73c928e289f2cf262d432db4a`](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/tree/509a34feea8541b73c928e289f2cf262d432db4a):

- [Official Heroic feature documentation](https://heroicgameslauncher.com/docs/faq)
  describes Wine Manager downloads and Wine Settings. Current
  [manager code](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/509a34feea8541b73c928e289f2cf262d432db4a/src/backend/wine/manager/utils.ts)
  reconciles cached releases with existing install directories and compatible
  architectures; discovery and installation are separate observations.
- [Downloader implementation](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/509a34feea8541b73c928e289f2cf262d432db4a/src/backend/wine/manager/downloader/main.ts)
  has progress, unpacking, abort/error handling and optional upstream SHA512
  checks. It warns rather than refuses when no checksum exists; Ode does not
  adopt that weaker trust policy or its destructive update/removal semantics.
  [Repository constants](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/509a34feea8541b73c928e289f2cf262d432db4a/src/backend/wine/manager/downloader/constants.ts)
  identify Heroic Wine-Crossover builds, **not the commercial CrossOver app**.
- [WineVersionSelector](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/509a34feea8541b73c928e289f2cf262d432db4a/src/frontend/screens/Settings/components/WineVersionSelector.tsx)
  resolves actual binary paths, reports missing versions and retains valid
  selected installations. The
  [install selector](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/509a34feea8541b73c928e289f2cf262d432db4a/src/frontend/screens/Library/components/InstallModal/WineSelector/index.tsx)
  separates global configuration, selected version and per-title prefix/bottle.
  Ode retains its own pinned-recipe and no-silent-substitution rules.
- [Porting Kit](https://www.portingkit.com/) describes itself in its official
  page metadata as a Windows-game/app installer using **Wineskin technology**.
  It is a product/wrapper workflow, not another Wine engine identity. Apple's
  [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
  and graphics payload identity are also distinct from provider identity.

The coordinator received this research and native UI proposal before
implementation: retain the grouped macOS Form; prominent provider observations
and real acquisition actions; configured default and exact registry selection;
progressive disclosure for legacy bottles, graphics declarations and diagnostics.
Use standard Pickers, buttons, selectable locations, semantic text and adaptive
action rows, with explicit missing/checking/error/unsupported states. Actual
download controls use only the pinned, trusted release. Source/native render
evidence, installed delivery and product acceptance are separate gates.

## Calimocho release engine discovery (REQ-115/B3, first beta)

- Xode discovers only `~/Library/Application Support/Xode/Engines/<engine_id>/calimocho-engine.json` (schema `calimocho-engine/1`). The folder name must equal `engine_id`, and the folder must not be a symlink. The active pin is `calimocho-11.20-4.0b3-06` (version `0.1120.4.6`; wine `803a62d1…2505`, wineserver `7102d704…01d0`, descriptor `d3ca32d8…18ff`, `MANIFEST.sha256` `db1b642e…28bf`, Team ID `M62Z4M5EUY`). Release -04 remains an older compiled pin and default-catalogue binding for the alongside update path.
- The app runs a fast local pre-filter: it hashes the descriptor, the `MANIFEST.sha256` file itself and the `wine`/`wineserver` binaries against the compiled pins, and checks their code signatures against `anchor apple generic and certificate leaf[subject.OU] = "M62Z4M5EUY"`. The app does **not** verify individual manifest entries or the rest of the tree; backend `engine-inspect` does (descriptor hash, every manifested file and link, no extra entries, signatures). It expands `${ENGINE_ROOT}` and refuses `DYLD_*`, `MTL_HUD*`, `PATH`, `HOME`, unknown variables, absolute paths and paths that escape the engine folder. It then renders a private local registry with absolute paths.
- Backend `engine-inspect` remains the admission gate. The Engines pane shows Calimocho as Ready only when the pre-filter passes **and** `engine-inspect` admitted this exact engine (name, Wine and wineserver digests); launch re-inspects and refuses when it isn't admitted. Admission checks identity and integrity only: it is not title qualification, and it grants no right to bundle or redistribute Apple GPTK components. X Ode points to the owner-published archive but does not bundle or republish the engine.
- Shipped defaults pin the release engine by name and its wine/wineserver pins, not by a registry path or digest. If the engine is missing, Play says that Calimocho isn't installed and nothing else is substituted.
- The published -06 archive URL is `https://github.com/WorkingPrinciple/calimocho/releases/download/engine-0.1120.4.6/calimocho-11.20-4.0b3-06-macos.zip` (200,075,043 bytes; SHA-256 `3fc4467b466b6f8f0855c1934b2fe6a3d1c02b0c5ca85037860b735e4e419ee5`; expanded ZIP entry bytes 695,625,804). The owner confirmed publication and the FH6, Brotato, Halls and Vampire Survivors gameplay gates (COR-216); installed app E2E remains separate. “Get Calimocho” downloads in-app, checks free space, exact size and SHA-256, validates the ZIP layout and extracted links, extracts into private staging with `/usr/bin/ditto`, verifies the release, and places it without replacing an existing engine. Cancelled or failed installs clean staging. Backend admission remains the only Ready gate.
- Engines and sign-in readiness share install progress and cancellation. The Engines pane offers Show in Finder and confirmed removal to the Trash; removal refuses while a game or game operation is active, and does not modify prefixes or saves. After install or removal, Ode refreshes engine admission. It never treats the local archive check as Ready.
- Normal quit cancels an active install and waits for extraction to stop and staging cleanup to finish. Extraction gets SIGTERM, then SIGKILL after two seconds if needed, with a further bounded wait; a failure to stop refuses quit and retains staging. Later quit attempts recheck the surviving extractor and allow quit once it exits. Before a later install checks disk space, it reclaims interrupted staging folders only when they are at least ten minutes old, have the install UUID name, are real private directories owned by the current user, and no other installer holds the Engines-root lock. Younger stages are left alone because an orphaned extractor may still be writing. Extracted symlinks must resolve inside the canonical engine root, including through other links.
- **Calimocho updates (REQ-123):** Engines Settings shows the installed release version and Check for Updates. Only opening that pane triggers an automatic public GitHub releases check, at most once per 24 hours (manual checks remain available). App launch does not check. The unauthenticated check includes `engine-0.1120.4.N` prereleases; it never trusts release metadata to authorize a binary download. Offline, GitHub rate-limit and other failures are shown without changing the engine.
- Version discovery accepts only exact release-shaped engine names matching their descriptor version; title-specific folders such as `calimocho-11.20-4.0b3-01-fh6` are ignored. Older release versions remain display-only update sources, never download authorization. Acknowledgments selects the installed active pin, then the newest installed compiled pin, never an unpinned folder.
- If this app pins a newer release than the installed engine, Update Calimocho uses the same pinned installer alongside the old folder while holding the game-operation reservation. Backend admission must succeed before changing any selections, and only a default or Brotato/Halls override pointing at the old Calimocho release is changed. CrossOver, custom choices and other titles, including FH6 and NMS, are untouched. Admission refusal or cancellation removes the newly installed folder and preserves the old engine and selections. Only after success is a confirmed Move Old Engine to Trash action offered; that offer survives relaunch. An interrupted update with the new folder already installed offers Finish Update when Engines opens, reusing the folder but requiring admission before activation. Refusal in that recovery path preserves the existing folder for retry. Future-dated check timestamps are stale and cannot suppress the daily check. An unpinned newer release instead shows its version, release notes and next-app-update guidance, never an install action. Independently signed engine updates are not implemented.
- **Temporary developer-local exception:** No Man's Sky keeps its private `calimocho-wine11.20-gptk4b3-tls-vulkan-private` binding (`developerLocal: true`). It resolves only when the exact pinned registry exists and hash-verifies on this Mac. On any other Mac it reports that the tested engine isn't installed, without substitution. NMS moves to the release engine only after a save-backed qualification, which is a separate decision. Release notes for the first beta must state this exception.
- **FH6 deferred to 0.2.1:** The -06 repin changes only Brotato and Halls. FH6's CLI recipe needs a title-specific `-06-fh6` registry identity and a `d3d12_tsshim.dll` prefix overlay, with no native `windows.web` override. The existing admitted-selection launch path refuses prefix overlays and requires the unchanged admitted registry; supporting that recipe is not configuration-only. FH6's existing app binding and opt-in remain untouched.

## Persisted launch selection (M3)

### Current Calimocho execution policy (REQ95 / COR110)

Current Play accepts only an explicitly selected, admitted Calimocho configuration.
CrossOver, GPTK and generic Wine records remain historical data; detecting them or
retaining an old preference does not permit execution or automatic substitution.
No default is invented by CrossOver detection.

Selecting Calimocho for a game persists the complete `engineSelection` alongside
`engineOverride` in the private installed-game list: registry path and byte digest,
engine name, admission result, Wine digest and wineserver digest. Reload uses that
game's saved tuple, not the current global registry or default admission.
Clearing an override clears its tuple without changing the independent default.
An enum-only Calimocho choice cannot be saved or launched.

The resolver reads that exact registry, matches the actual Wine/server fields,
and refuses changed bytes, missing/unusable artifacts, unadmitted selections,
conflicting title recipes and sibling fallbacks. The resolved tuple travels into
the launch service's fresh, identity-bound `engine-inspect` check immediately
before launch; it is not replaced by a second global preference read.
Artifact admission remains distinct from gameplay qualification.
The legacy bash argument-two/`XODUS_ENGINE` handoff cannot establish identity and
does not execute under current policy. Historical script/session regressions use
an explicit diagnostic entry point compiled out of shipping builds; normal Play
never calls that entry point.

Prefix preflight runs off-main, reads the CLI's existing sibling ownership record,
and refuses a conflicting or malformed record without writing it. A nonempty
unmarked prefix is explicitly displayed as `legacy-unclaimed`; it is used as-is,
not claimed, migrated or moved. The CLI repeats its own ownership checks.
No prefix or save is inspected during source checks except synthetic fixtures.

The owner-directed NMS free recipe binds only product `BQVQTL3PCH05` at the
confirmed `~/Games/Xodus/NoMansSky-Xbox` folder: exact PERF registry digest
`170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609`,
engine `calimocho-wine11.20-gptk4b3-tls-vulkan-private`, runtime candidate
`7106d0712618544b130e8c0ebcb0881ebd663155e14c24a698445746b82ca51b`,
existing `req71-nms-calimocho-port11b-v1` prefix, `Binaries/NMS.exe`,
local saves, online environment and no auto-dismiss. It requires explicit matching
admission; it does not silently select the latest engine. No new HUD/fullscreen
setting, prefix import, reseed or registry rewrite is applied. The historical
CrossOver recipe is retained as evidence, not admitted for current Play.
Account-bound CLI launch already uses the isolated management/Ode profile;
the historical `--account-profile launch` flag adds no distinct authentication
semantics to that lifecycle route.

### Historical selector handoff

The following M3 description documents the old imported-game contract, not
current execution admission.

Launch selection is separate from the configuration-only planning contract below.
`Xodus.defaultEngine` persists the optional default. The private installed-game
list persists each game's optional `engineOverride`; override, default, then
first available runner was the selection order. A missing selected runner was an
explicit refusal, never a substitution.

Availability does not read `Xodus.developerBackendPath`: that preference names a
management build, not a runtime. CrossOver availability uses the signed-bundle
check below. Each Experimental provider has its own user registration at
`Xodus.runner.PROVIDER.executable`. Detection independently checks every
registered absolute path for a regular executable file, irrespective of the
default or override. These registrations declare provider identity; observed
file availability does not verify GPTK provenance/version, a license, compatible
prefix, graphics, or gameplay. No standard GPTK3/4 installation layout is guessed.
Blank, relative, missing, linked or non-executable runner files are unavailable.

The live Library's installed cards, hero and game menus expose overrides and
detected format labels. Selecting a provider hands its identifier to the saved
game launcher as argument two and `XODUS_ENGINE`. **This is a selector-handoff
contract, not proof that a private launcher actually invokes that runner.**
Registration paths are availability inputs, not an applied runtime command.
The private launcher must implement provider selection while preserving its
bottle/prefix, streaming, service, stop and save behavior. That integration and
actual game execution remain in the separate authorized Mac runtime lane.
CI checks distinguish selector handoff from successful gameplay.

## Installed package facts (M1)

`PackageType` is a format fact, not a support or compatibility verdict.
`MicrosoftGame.config` alone does not prove MSIXVC. The inspector requires an
observed 4096-byte MSFT-XVD header in a regular `.msixvc` file (including the
existing streaming marker). A loose GDK build with validated DOS/PE headers is
Win32; otherwise absent format evidence is Unknown. Filenames alone do not
establish PE or MSIXVC, and directories/symlinks are ignored.
Encrypted Appx recognition requires an `EXPH` signature and a fully available,
bounded header; empty `.eappx`/`.eappxbundle` download placeholders are not
evidence. Other encrypted-container signatures remain Unknown until validated.
This is signature/header recognition, not decryption or integrity validation.
Header reads check descriptor/path identity, size and modification/change times
before accepting an observation. MSFT-XVD recognition likewise does not verify
the complete container, entitlement or payload.

Bounded Appx manifests derive application-model facts from application entry
points and runtime/trust declarations, not `Windows.Universal` device targeting.
Desktop-only UWP applications are included; full-trust/hybrid applications are
classified Appx. Malformed/unreadable manifests are inspection errors.
Classic applications with the documented `appContainer` trust combination or
legacy `windows.partialTrustApplication` entry point remain Appx, not UWP.
Recognized application-model attributes must resolve to the Microsoft UAP10
namespace; unrelated extension attributes/elements cannot invent an application
model. Prefix rebinding is tracked, and ambiguous or contradictory recognized
declarations are refused.
Observations are refreshed on load and reimport, including prior Unknown
records; temporary unavailability preserves the last saved type and exposes an
error. Reimport changes format facts without discarding a user engine override.
Observation generations fence asynchronous refreshes; an old load inspection
cannot replace newer reimport observations. Store updates additionally compare
the observed import date before writing refreshed package facts.
No UWP/EAppx support status or installation policy is changed.

Official, separately installed CrossOver is required for CrossOver launch routes,
not a universal dependency for every configured engine or game.
The account-bound resolver reuses the current `CrossOverDetector` observation
when the final selected registry record has `kind:"crossover"` (case-insensitive),
including recipe-pinned and fallback selections. Missing, unverified or incomplete
observations refuse that route before prefix resolution; they do not substitute
another engine. This app dependency check does not authenticate the registry
executable as part of the detected bundle or replace backend artifact validation.
Generic Wine and Calimocho admission remain independent of this CrossOver check.
GPTK3/GPTK4 and user-selected standalone/source-built Wine remain Experimental
tracks; any explicit graphics override is also Experimental. The UI requires
acknowledgement before their pure planning, reset by configuration or observed
installation changes. No DXMT API/renderer is invented by this policy.

`CrossOverDetector` checks `/Applications/CrossOver.app` and the current user's
`Applications/CrossOver.app` only. It bounds Info.plist to64KiB, rejects linked,
nonregular, multiply-linked, unsafe or unstable metadata, and verifies static
code including nested code/all architectures against this fixed requirement:

```text
identifier "com.codeweavers.CrossOver" and anchor apple generic
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
and certificate leaf[subject.OU] = "9C6B7X7Z8E"
```

Trust source: the user-approved official vendor installation independently
checked by existing operators, with strict/deep verification and Gatekeeper
Notarized Developer ID acceptance. This is a scoped approved installation
baseline, not a retrieved vendor-published team allowlist or live notarization
lookup on each app check. Candidate metadata cannot supply the trust pin.
Security's requirement parser takes the plain expression; only the `codesign
-R` CLI needs `=` to distinguish inline requirements from filenames.

Observed short version26.3 and build26.3.0.39832 are distinct. A verified
observation defaults only an unset profile to CrossOver/providerVersion26.3;
Wine and graphics identities remain unknown. Existing explicit decoded/selected
configurations, including a deliberately cleared choice, are not rewritten.
The current UI is memory-only; this does not introduce persistence/migration.
Library/Account/Settings share checking/absent/unverified/verified presentation.
Absent/unverified CrossOver blocks CrossOver runtime-plan setup, not public
browsing or Microsoft sign-in. No license, game, device, existing bottle, save,
credential or provider process is inspected/executed by this separate app check.

The configuration-only backend contract remains unchanged.
Management C95, its 25 operations/capabilities and null runtime fingerprint
remain unchanged; install/play stay gated.

App-consumable source entry is `xodus runtime-plan`, separate from management.
Write exactly one Configuration JSON object to stdin and close the write end
to supply EOF. Exit zero returns exactly one ConfigurationPlan JSON object
plus LF on stdout; invalid input or IO failure returns nonzero, with a static
stderr diagnostic and no valid success plan. The caller must discard output
on nonzero exit and own its cancellation/deadline. Input is byte-bounded even
without EOF; a short input requires EOF, so callers must not keep stdin open.
The route returns before account/log initialization and never executes a
provider, probes a device, reads a runtime path or creates a prefix. Deployment
of a new binary is separately gated; this entry is not present in frozen
authentication engine source943 or any held production artifact.

Canonical schema: `contracts/runtime-providers-v1.schema.json`, namespace
`urn:xodus:runtime-provider-configuration:1`. Neutral configuration/plan and
negative fixtures: `fixtures/runtime-providers-v1.json`. Rust implementation:
`xodus_management::runtime_provider`. Input JSON is 1..16384 UTF-8 bytes;
duplicate, unknown, incompatible, missing nullable and invalid metadata fields
are explicit `INVALID_REQUEST` failures, never an installed/launchable fallback.

Configuration exact keys are `version`, `provider`, `providerVersion`, `engine`
and `graphics`. Engine keys are `kind` (`wine`), `provenance`, `version` and
`artifactSha256`. Graphics keys are `backend`, `provenance`, `version` and
`artifactSha256`. Nullable keys are required and use null when unknown.
Version strings are bounded printable ASCII, not inferred from a provider label;
artifact identities are nullable lowercase SHA256, declared rather than
attested. Provider/package, Wine engine and graphics component versions are
independent. Wine11 with D3DMetal4 is admissible configuration, not GPTK Wine7.7
equivalence or demonstrated compatibility.

| Provider value | Engine provenance | Proposed preset graphics |
| --- | --- | --- |
| `gptk3` | `appleToolkit` | `d3dMetal` / `appleToolkit`, version unknown |
| `gptk4` | `appleToolkit` | `d3dMetal` / `appleToolkit`, version unknown |
| `crossover` | `userInstalledCrossOver` | null/unconfigured, not a guessed renderer |
| `standaloneWine` | `userSelectedWine` or `userSelectedSourceBuild` | null/unconfigured |

Graphics backends are `d3dMetal`, `dxvk`, `wineD3d` or null. Provenance is
`appleToolkit`, `crossOverBundled`, `engineBundled`, `userSelected` or null.
A configured backend requires provenance; a null backend requires all graphics
metadata null. Preset choices are proposals, not observed installation proof.
No commercial Apple redistributability claim, copied CrossOver, licensing
bypass or globally installed provider discovery is included.

`plan` validates real configuration and returns a fresh generation UUID and
safe relative path `runtime-prefixes/v1/CONFIGURATION_SHA256/GENERATION_UUID`.
The configuration identity covers provider/version, engine identity/version/
provenance and graphics identity/version/provenance. The reference hashes the
compact Rust serialization in documented field order; consumers may use the
returned plan and must not assume arbitrary JSON key order hashes identically.
Every plan allocates a new generation, including either component change;
there is no path reuse, migration, prefix creation or save relocation. Persisting
a plan and later reusing its generation requires a separate checked lifecycle,
not a call to this planning function.

Plan fields are `version`, `configuration`, `generationID`,
`prefixRelativePath`, `installation`, `devicePreflight`, `gameVerification`
and `launchable`. The latter four are independently `notInspected`,
`notPerformed`, `notVerified` and false. Configured metadata or declared hashes
never promote these evidence states. Installed component verification,
device/backend preflight, exact per-game/version results, authorized content,
licensed RPS/runtime pairing and supervised launch remain separate release
gates. No trial certificate transfers across an engine/backend generation.
