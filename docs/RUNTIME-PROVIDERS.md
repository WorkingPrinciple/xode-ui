# Runtime provider configuration v1

## Persisted launch selection (M3)

Launch selection is separate from the configuration-only planning contract below.
`Xodus.defaultEngine` persists the optional default. The private installed-game
list persists each game's optional `engineOverride`; override, default, then
first available runner is the selection order. A missing selected runner is an
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

Official, separately installed CrossOver is the first-release dependency.
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
Absent/unverified CrossOver blocks first-release gameplay setup, not public
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
