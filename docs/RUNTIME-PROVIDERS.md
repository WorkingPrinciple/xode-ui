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
- **Developer-local exception (development builds only):** No Man's Sky's private `calimocho-wine11.20-gptk4b3-tls-vulkan-private` binding points at a source-tree registry, so packaging strips it (REQ-52). Packaged builds report that engine as unavailable and offer No Man's Sky through its admitted CrossOver route. Development builds still resolve it only when the exact pinned registry exists and hash-verifies on this Mac, without substitution.
  Packaging also drops the No Man's Sky title profile bound to that engine, so its preserved-prefix name and run wording never ship.
- **CrossOver registry location:** the `crossover-26.3-mvk142` binding reads `XodusCLI/renderers/moltenvk-1.4.2-private-api-x86_64-cor224/` under Application Support. The backend renderer install creates that directory, and the binding pins the registry digest at that path, so the app keeps the name rather than rewriting it at staging. A neutral name needs a backend renderer-install change plus a migration of the installed directory.
- **FH6 title contract (REQ-125, source candidate):** FH6 requires `calimocho-06-fh6-v1`, Store ID `9NR1R1XWLCNB`, package identity `Microsoft.ForteBaseGame`, executable `forzahorizon6.exe` and the `calimocho-11.20-4.0b3-06-fh6` alias. Plain -06 is refused for FH6; the alias is refused for every other title. The alias is rendered locally only from the fully verified -06 release, with the exact 19-key Forza environment and a single pinned tsshim overlay. Its actual registry digest remains bound at inspection and launch. It cannot become the global default.

FH6 additionally requires the producer's `titleRecipeV1` capability and fresh
`title-recipe-inspect` evidence, separate from unchanged `engineAdmissionV1`.
Launch passes `--title-recipe` and `--package-identity`; the producer independently
checks the installed package, explicitly completes Wine prefix update and server
synchronization on every launch, then reasserts and verifies
`d3d12_tsshim.dll` in `drive_c/windows/system32/d3d12.dll` before spawning the game.
The expected SHA-256 is
`c72b5cae6d3da617b482086193ffeb99616a07c18383e629f4bbec0a4b16c1f5`.
Wine update can replace that destination with builtin d3d12; copying only before
wineboot or only on prefix creation is insufficient. Preparation failures prevent
game start. The app requires the bounded private `title-recipe.json` evidence
to agree with the result receipt, registry, prefix, source and final overlay hash.
This attests staged bytes, not loaded modules or gameplay qualification.

The title prefix is `Prefixes/9NR1R1XWLCNB/calimocho-06-fh6-v1`; existing release,
private and UUID prefixes are not adopted or changed. No shim directory is passed
for this recipe, and `windows.web=b` requires Wine's builtin implementation.
Other titles retain their existing runtime/shim contracts and the blanket refusal
of arbitrary admitted overlays/imports/DLL overrides. The app-pinned runtime pair
still needs a70's fresh-prefix sign-in/free-roam and forced-update live checks;
source/mock checks do not establish that product gate or a signed producer rebind.
Normal builds keep the FH6 launch gate closed until that live receipt is admitted.
A separately labelled qualification candidate may be compiled with
`-Xswiftc -DXODUS_FH6_QUALIFICATION`; this opens only the app feature gate, never
the engine/title admission or preparation checks. It is not release qualification.

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

Compiled Calimocho releases use stable `Prefixes/<product ID>/calimocho-<Wine version>`
keys, independent of installation UUID and release revision. Only after fresh backend
admission, launch can clone a single known same-Wine-line release prefix from a
proven installation UUID into that stable location. The previous tree and ownership
record remain untouched; the new ownership record binds the admitted release and
Wine digest. Wine's external symlinks are copied as links, not followed. Existing
stable prefixes are never overwritten. Unknown or conflicting ownership and
ambiguous installation histories refuse adoption rather than guessing. Uninstall
retains prefixes and records UUID-to-product provenance before removing the Library
row, so reinstall can find the old saves. Already-orphaned UUIDs with no product
provenance are not guessed. Apple4, lp and preserved NMS prefixes are unchanged.

Quit, logout and shutdown ask for confirmation when a game is running, before
closing runtime activity. The warning names the game and explains that unsaved
progress may be lost. Cancel is the default; only **Quit and Close Game** proceeds.

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

## FH6-only runtime replacement (REQ-125)

The separate REQ-125 FH6 runtime pin is primary
`e4c1085b4991e7af50e7e6a06245a7948d9911ae2d12b87e8fc035aacd671cb2`
and legacy `1fb7b7c81a64c82ca2f4ea1bdc260826fe8ced3b09738e987d836eabb488b768`,
bound only to FH6. a70's frozen provenance SHA-256 is
`762ba5431a3c2471f97a6a65892d12e27312ddb1b528549b769b7f0e12992e00`;
its source-tree manifest is
`ffce9cbf41b2813cba12602be6bf3a584ac82e3fc638bd50a9f90169d2f54220`
(untracked `xgr-01` source, not a source Git commit). The reported fresh-prefix
run reached free roam for roughly 9.5–10 minutes, with a preparation receipt,
stable overlay digest and no observed asserts/crash reports. This is not
installed-app or non-FH6 qualification. The app-support candidate path requires
separate authorized staging; no runtime is copied by this source change.
The failed `6c9d…/cfe7…` FH6 pair and retracted `da60235f…` primary are not used
for this recipe. Other titles retain their existing pairs. Ordinary FH6 builds
remain default-closed pending coordinator acceptance.

## Signed update index verifier (REQ-123/124, isolated candidate)

`CalimochoIndexVerifier` implements the stable verifier contract from Calimocho
`fc996c3b`: byte-exact DSSE PAE/Ed25519, explicit key-to-epoch trust,
revoked signing keys, embedded floor, rollback and same-version equivocation
checks, strict duplicate-free JSON and canonical base64, bounded parsing,
whole-string patterns, exact release URLs, freshness and strictly-newer
numeric version eligibility. Errors are explicit; verification has no engine
mutation or launch-admission side effects.

The Settings integration is **default-closed**. Only an explicitly labelled
`-DXODUS_SIGNED_ENGINE_INDEX_QUALIFICATION` build uses the signed-index client
in the existing Engines pane-open/manual check; ordinary builds keep their
existing pinned-update behavior. The client embeds only the reviewed production
public anchor from `fc996c3b` (trust blob SHA-256
`035bf651ddef3b6544f4c8a28f59d8d2e60758215c8df984472d3ec1e59c9d5a`),
never an RFC or fixture key. No production signed index is asserted to exist.
The strict state codec keeps `high_water`
separate from `revoked_engines`: revoking a signer resets only the mark, and a
revocation union over 1024 fails closed. Verification returns a new state only
after all checks pass. The client fetches anonymously with an ephemeral session,
allows at most five HTTPS redirects, enforces envelope bounds while streaming,
and serializes state updates with a private lock. It writes a private temporary
state file, synchronizes it and renames it only after verification and eligibility
checks succeed. An invalid, expired or unavailable index clears the offered
signed update and reports the reason without mutating installed engines.

The signed index only drives release information. A newer unpinned release gets
release notes and compatible-app guidance, never an Install action. The existing
compiled-pin installer and fresh backend admission remain the only activation
path. No new index-authorized archive extraction is exposed; its stricter
streaming extraction contract remains a separate gated implementation.

Run the standalone checks against the frozen upstream public test vectors:

```sh
swiftc Sources/XodusPreview/CalimochoIndexJSON.swift \
  Sources/XodusPreview/CalimochoIndexVerifier.swift \
  Tests/EngineIndexChecks/main.swift -o /tmp/calimocho-index-checks
/tmp/calimocho-index-checks /path/to/frozen/tests/engine-index
```

The checks exercise the upstream known-answer vectors and local parser,
state and bounds regressions without network access, installation or activation.

## Highball provider (REQ-127, user-installed)

Highball (`app.highball.Highball`, Team ID `B95M7DARU4`) is a third,
user-installed provider. X Ode never installs, updates, modifies or launches
Highball and never accepts its licences (GPL-3.0 app; separately licensed Wine
and graphics components) on the user's behalf.

Engines Settings shows one of three states:

- **Not Installed** with a Get Highball link to the upstream repository.
- **Detected** when `/Applications/Highball.app` is a non-writable directory
  with the exact bundle identifier and a valid publisher signature. This is a
  read-only check with no execution. Without a backend verdict, the row stays
  Detected and is never Qualified.
- **Qualified for Brotato only** when the paired backend answers
  `highball-inspect --contract-version 1` with `highballAdmissionV1` and
  `highball-inspect --product 9P9VNSQK1W3K` returns a consistent qualified
  verdict for that product (exit status 0 only when qualified). Any other
  product, a disagreeing exit status, an unsupported contract or a missing
  backend yields no verdict.

Shipping builds run the inspection only through the approved shipping pair
identity, on a dedicated inspector that is closed on quit. Launch admission and
the separate Highball prefix are backend responsibilities; this row grants no
launch.

### Title-scoped provider launch (COR-224, REQ-127)

The app's `engine-inspect` decoder accepts exactly three admitted providers:
`calimocho`, `crossover` and `highball`, and only when the declared and
admitted providers match. Any other provider fails closed. Calimocho remains
the only global default. CrossOver (`crossover-26.3-mvk142`, the reviewed
signed-renderer registry `c246dd29…` already on this Mac) is offered only in
No Man's Sky's per-game Engine menu. Highball (`highball-x64-crossover26.3-r27`)
is offered only for Brotato. Both are developer-local catalogue bindings, and the
app refuses either one for any other title before launch.

The Highball registry has no fixed bytes. X Ode renders it into its own
registries folder from a qualified `highball-inspect` verdict whose entry
matches the pinned engine path and hashes. The backend re-checks it at
`engine-inspect` and again in its launch gate (managed prefix, never a Highball
bottle). A title-scoped selection does not apply the title's Calimocho launch
profile. It launches on a fresh X Ode prefix for that installation and engine.

## FH6 and Hades runtime pair 15e6d1e (REQ-125, REQ-32, REQ-128)

FH6 and Hades now bind L12's runtime from private commit
`15e6d1ef8f6df24c78e860086b950d4a5a203c50`: primary
`a64fefb1041c476bf9b064abaf4cad6ea30559fd25b35bbe6e2ff603a23f6257`,
legacy `dfeea51fb0c59d91f7ad71f43a1263e8318ed89379a672a953954121014196af`.
It replaces the earlier FH6-only `e4c1085b…`/`1fb7b7c8…` pair above.
The pair carries the REQ-125 assert-to-warning change, the REQ-32
`E_GAMEUSER_NO_MSAAPPID` result and the REQ-128 add-on licence path.

Run evidence on this exact pair:

- FH6: run `57a4a57d-e87f-4091-9789-afa3fb1a6c67`, pinned
  `calimocho-06-fh6-v1` recipe, 688 s, CLI and Wine exit 0, no assert or
  FH206.
- Hades: run `136cf1b4-bf79-42e7-ab44-24cb66f6339f`, `hades-mscoree-v1`,
  title screen, WM_CLOSE exit 0. Sign-in still fails at the RPS ticket
  bridge with 0x89245115 (REQ-32).

Two build deviations are recorded in `provenance.json`. The snapshot lacked
`xgameruntime.def`, so a byte-identical upstream copy was used; it is now
committed in private `af76233`. The `widl` wrapper only added an include path.

Every other title keeps the `7106d07…` candidate (`6c9d97d3…`/`cfe7e5f8…`),
which its own run evidence used. Runtimes are staged locally under
`~/Library/Application Support/Ode to X/Runtime/candidates/<primary sha>/`,
with `SHA256SUMS` and `provenance.json`. They are not bundled in the app.

### Runtime pair e63bc66 (supersedes efcbf2a for FH6 and Hades)

L12 commit `e63bc665c9d2ab276b2dea533bcef538456ce749` (tree `91982592`): primary
`ce316019739a4f80fb893af64f2e91f77d6de111af70bb260a7b19970d54a360`
(5,062,605 bytes), legacy
`3cae73b96d3a38cbef57aa63e4146614cd7e35517a1ce15b1f1877550509c1d1`
(8,988,323 bytes). Unsigned Windows PE, verified by SHA-256 before launch. It
contains `efcbf2a`, `073b317` (silent registration for protocol activation and
audio endpoint changes), and `user_GetAuthorization` now converts with
`WC_ERR_INVALID_CHARS`, which fixes XSTS token acquisition for every title. The
qualification runs below were on `efcbf2a`; the coordinator directed this pin.
The scope is still FH6 and Hades. The pair is staged at `Runtime/candidates/ce316019…/`.

### Runtime pair efcbf2a (supersedes eec6a13 for FH6 and Hades)

L12 commit `efcbf2ac52e07f57099e52b1704fe2e884983e39`: primary
`b28f3546413cdf3c6629c250bb7752159882183c901ba8efbb88cd1c846fd17e`
(5,062,605 bytes), legacy
`e077a50e03ea2f9c1b68f1094d2f273169d78a4d2b22981dc5c66b0cb9198fb5`
(8,988,287 bytes). Unsigned Windows PE, verified by SHA-256 before launch.
Over `eec6a13` it accepts a GUID `MSAAppId` for SISU, makes
`XSystemGetXboxLiveSandboxId`'s `sandboxIdUsed` optional, and resolves `wss`/`ws`
token URLs through their `https`/`http` endpoint. L12 qualified it on fresh
prefixes with no input and WM_CLOSE: FH6 run `4efdf51d` (fh6-compat pressed
"Ignore Warning", sign-in and licence completed, 331 s, no self-exit, exit 0) and
Hades run `175cb421` (`hades-mscoree-v1`, title window for 75 s, expected
REQ-32 line, exit 0). L12 also ran DREDGE on the equivalent `848819f` pair, but
its visual check is pending and DREDGE has no title profile yet, so the scope here
stays FH6 and Hades. The pair is staged at `Runtime/candidates/b28f3546…/`.

### Runtime pair eec6a13 (supersedes 15e6d1e for FH6 and Hades)

L12 commit `eec6a1390b1af1e037ed0590f9ddbea2c2f629e7`: primary
`35c1430522b9cf3f9940803512959700418cfc7b3ab3d72958cbafa8e47d139f`
(5,062,605 bytes), legacy
`a791b0285988229e7b95702f4611a415e46a25aaeed87f9aa13059956ca77aca`
(8,987,889 bytes). Unsigned Windows PE, like every earlier runtime pair; the
app verifies the pair by SHA-256 before launch. Its verified licence catalogue
now covers FH6 and 44 more titles, so `XStoreQueryGameLicense` succeeds for owned
full SKUs; trials are excluded. This fixes FH6 quitting about 150 s after going
online. The `cdd54e5` pair with the same code was live-checked (licence
validated, FH6 stable for 762 s, exit 0). `eec6a13` adds catalogue entries only
and was not run again; the coordinator waived that run. The scope is still FH6
and Hades only. The pair is staged at
`Runtime/candidates/35c14305…/` with `SHA256SUMS` and `provenance.json`.
