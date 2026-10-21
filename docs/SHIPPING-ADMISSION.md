# Local builds and release verification

## Purpose and authorization

### Supported local-candidate build

`tools/build_local_candidate.py` builds an engine from a clean committed checkout
with offline locked Cargo, compares its management contract with the app's,
builds a clean app-source archive, and generates exact source and signed-byte
pins in that archive only. It does not edit release producer pins, accept
unsigned arbitrary external binaries, replace an installed app, launch sign-in,
or enable Actions.

```sh
python3 tools/build_local_candidate.py \
  --engine-source /absolute/engine-checkout \
  --output-root /absolute/owned-output-directory \
  --identity DEVELOPER_ID_CERT_SHA1
```

The output is **Ode to X Local Candidate.app**, accompanied by an observed
source/build/package inventory. It uses secure-timestamped hardened Developer ID
signatures, but is explicitly **not notarized or production-qualified**.
This local sign-in candidate does not bundle the legacy game-launch capsule or
Python runtime; their absence must not be confused with qualified gameplay.
Both source checkouts must remain clean and unchanged throughout packaging.
The packager supports Apple Silicon Macs and checks all three executables are
arm64. Actual native Cargo features/profile must match the live release build;
they are recorded rather than inferred from the command alone.

These are project packaging checks, not Apple requirements or an approval
authority separate from the owner.

The owner's authorization to build, sign, install and test locally is sufficient
to do that work. Do not repeatedly request permission for those same operations.
Do not require an independently approved receipt, a second reviewer, or manual
approval of every commit/hash merely to prepare or test a local candidate.
Record exact inputs and observed results automatically so the work is
reproducible. A generated receipt records what happened; it is not permission
to proceed and does not prove that an app works.

Source revisions, schema hashes and artifact hashes are versioned compatibility
inputs, not permanent prohibitions on development. When an authorized change
updates the engine or contract, update the corresponding consumer checks,
packaging metadata and regression tests together. Investigate mismatches before
updating pins; never remove a failing check or accept arbitrary inputs just to
make packaging pass.

Do not turn a production-release requirement into a reason to stop controlled
local implementation or testing. Conversely, a successful local build or
signature is not production readiness.

## Preserve these actual protections

- Keep credentials, content keys, signing private keys and tokens out of source,
  logs and receipts. Do not export credentials or alter credential ACLs/trust
  to avoid native authentication.
- Native password, MFA and consent steps remain with the user. Certificate
  creation and signing may be automated when the owner has authorized them;
  an outstanding native authentication dialog cannot be completed by approval
  in chat alone.
- Use a new owned output directory. Preserve the installed working app and
  account/game data while preparing a replacement. Install or replace only
  within the owner's authorized scope, with a recoverable previous version.
- Bind the package to its actual source, engine, helper, schema and resources.
  Check ownership, file type, permissions, sizes, hashes and signatures.
  Reject unexpected symlinks, malformed metadata and changed staged inputs.
- Do not silently fall back to another engine, credential owner, account or
  ad-hoc signature. Report an actual failure instead of manufacturing success.
- Keep unsupported installation/play actions unavailable; do not simulate
  entitlement, owned inventory or gameplay.
- Keep GitHub Actions disabled as requested.

## Current tooling: constraints to update, not additional policy

The original release-pair implementation predates the local-development policy
above. Its fixed producer is retained in `build_app.sh`; it is no longer the
only supported way to build a local candidate:

- `tools/build_app.sh` requires exact app commit/tree, unsigned CLI hash/size,
  provenance hash/size, a clean source tree, an owned output directory and an
  explicitly selected signing identity.
- `tools/shipping_pair.py` still pins producer
  `28f737df46b29cc195145425e3fd1397ebc09be3`, tree
  `1273ddaa50a6b3e77647aabb5bb170b1b525c922`.
- `tools/verify_shipping_package.py` expects that producer's management schema
  SHA256 `d2f4222e952f732396018a4c4576da24729bdbddde7dd1f95df3b84d7a6d324d`.
  The newer account/runtime contract and checked-in resource instead match
  `03afeb28e4e5b652712c2b6f29fe648fa05c842ea86a4920bd4f960bdbcc0529`.
  This mismatch currently rejects package verification. Resolve the complete
  producer/consumer pairing and its tests, not just the one checksum.
- `ShippingPairPins.approved` is nil in source. Packaging generates exact
  engine/helper pins in an isolated source stage. Changing this document does
  not generate those pins or make an existing package valid.
- Runtime executable and helper checks enforce owned regular files, safe
  permissions, exact sizes/hashes and matching helper metadata immediately
  before execution. Preserve those checks when updating the build path.

The expected release profile is opt3/debug0 with no debug assertions, overflow
checks or test mode; features are xodus/CLI empty, management live, native
Keychain and security-framework. Record the actual profile/features and explain
any intentional development difference rather than labeling a different build
as the expected release input.

Local candidate support must be explicit and tested. Do not claim that editing
this policy alone fixes the current scripts, admits a new producer, or produces
a usable app.

The separate local path was built and exercised on 21 October: app source
`a444f8fe5bb040b9d9d81e4263869385f7118977` and engine source
`96d91dbec6727b4a7409908352c48f09411d3508`. Its packaged engine passed two
fresh-process saved-account/runtime checks. The app and its separately installed
copy opened native Library windows with catalogue content and four local games.
All 24 packaged files matched the recorded inventory after copying, all three
executables were arm64 with timestamped hardened Developer ID signatures, and
deep strict signature verification passed. The original installed app was
preserved. Fresh app: `~/Applications/Ode to X Local Candidate.app`.
The owner subsequently authorized sign-out and completed a fresh native
Microsoft sign-in. Both the first candidate and an independently compiled update
passed two fresh-process saved-status/runtime checks each. The updated native app
then reopened with the sign-in saved and four local game cards, without another
login. The update uses app source `2a2555305485ddf6de1031b596ebf7747889e639`;
the previous local candidate and original Development app remain preserved.
This is interactive sign-in and local-update evidence, not qualified gameplay,
reboot/locked-Keychain coverage or notarization. Gatekeeper still reports
`Unnotarized Developer ID` (exit 3); no bypass was applied.

## Signing and saved-account access

Use the owner's valid Developer ID Application identity for new candidates.
Do not re-sign a preserved working engine in place. Sign a separate candidate
and regenerate its package identity metadata consistently.

Signing identifiers remain `io.github.dragoshont.xodus`,
`io.github.dragoshont.xodus.cli` and
`io.github.dragoshont.xodus.auth-host`. The existing signing helper uses an
exact certificate-leaf requirement. This is not yet a team-based renewal policy.
Certificate renewal therefore needs a tested identity update, not an assumption
that a matching team automatically satisfies the current requirement.

The owner authorized provisioning on 21 October 2026. A valid Developer ID
Application certificate was created for team `M62Z4M5EUY`; its SHA1 is
`410914520BCC840C0125D3826CCF0F247F603321`. Separate signed candidates passed
saved-account reads, noninteractive runtime authorization, same-binary restarts,
relocation and a fresh compilation. Abiotic package-license qualification also
passed without printing/saving its content key. The preserved original owner
retained access afterward. See [the evidence](UNIFIED-ACCOUNT-SPEC.md).

Do not require two independently human-approved build receipts to test rebuild
persistence. Build into a fresh target directory, record source/toolchain/
configuration and unsigned/signed identities, then exercise the actual saved
account with that artifact. Re-signing the same binary is not a rebuild test.
The existing command below compares requirements only; it does not run that
account-access test:

```sh
python3 tools/signing_identity.py compare --kind cli --identity CERT_SHA1 \
    --first /absolute/first/signed-cli --second /absolute/second/signed-cli
```

Do not promise that all future builds, reboots or locked-Keychain situations
will be prompt-free. Test those scenarios separately and report their outcomes.
Do not revoke an unidentified certificate or delete the old signing identity
while the working app still depends on it.

## Local testing versus distribution

`XODUS_SHIPPING=1` excludes fixture state, synthetic install/job success,
illustrations, exports and native test entrypoints. It uses bundled engine/
helper paths and rejects development arguments and backend overrides.
Nonshipping products remain available for explicitly requested development.
Preserve that separation; a local candidate need not be called a production
release to be useful.

`tools/check.sh` is the documented regression entrypoint. Capture each failure
truthfully and continue independent checks where useful. A passing subset does
not make the full command green. Synthetic checks do not replace live account,
UI, package-consumer or gameplay observations.

Developer ID signing alone is not notarization. The current signing helper
defaults to local signing with `--timestamp=none` and no hardened runtime.
Its explicit `sign --developer-id` mode requires a valid Developer ID Application
certificate and requests a secure timestamp plus hardened runtime:

```sh
python3 tools/signing_identity.py sign --kind cli --path /absolute/new/candidate \
    --identity CERT_SHA1 --developer-id
```

Do not apply that mode to an installed working binary. Hardened-runtime
compatibility still needs live testing; no permissive entitlements are added
automatically. `build_app.sh` does not yet select this distribution mode.
Gatekeeper rejected
the observed candidate as `Unnotarized Developer ID`. A distribution path needs
appropriate signing options/entitlements, notarization and applicable ticket/
Gatekeeper verification. Do not disable Gatekeeper or remove quarantine to
pretend those checks passed. Submission to Apple's notarization service is a
separate external operation; do not send credential stores or private evidence.

Call the product production-ready only after verifying the integrated app's
actual sign-in, restart/update behavior, error recovery and supported user
flows. A package-license check is not a launched game; standalone Wine controls
are not Xbox-route gameplay. Keep measured results, remaining defects and
untested scenarios distinct. Owner authorization permits the work; it does not
turn an untested result into a pass.
