# Controlled local shipping boundary

`XODUS_SHIPPING=1` selects a different SwiftPM source set, not a runtime demo
toggle. Fixture views/state, game illustrations/resources, synthetic core
install plans/jobs, exports, native check entrypoints and the authentication-host
check corpus are excluded. Live Library/Discover/Downloads and Account show
native state and actual management data. Unsupported game installation/play
does not get a simulated action. The nonshipping preview/test products remain
available for explicitly requested development.

Shipping ignores `XODUS_BACKEND_PATH` and remembered developer selection,
has no engine picker, rejects preview/test/development argv, and resolves only:

- `Contents/Resources/XodusEngine/xodus-cli`
- `Contents/MacOS/XodusAuthHost`
- `Contents/Resources/XodusAuthHost.json`

The repository's `ShippingPairPins.approved` is nil. This compiles, but management
and pure planning fail closed before any process. Packaging generates a
stage-only Swift pin table after independently approved sealed inputs and
separate signing. The table binds schema1, approved app commit/tree,
the pinned producer/tree, signed engine/helper SHA256 and byte sizes, helper version1
and matching helper source. Runtime JSON, HELLO and ad-hoc signing alone cannot
create that approval.

## Operator trust chain

`tools/build_app.sh` requires the exact externally approved app commit/tree,
unsigned CLI SHA256/bytes, adjacent provenance SHA256/bytes and a new owned output
root. It refuses a dirty/mismatched source and does not overwrite an old app.
The provenance is hash-pinned before parsing. Duplicate keys, wrong source/tree,
nonrelease profile, unexpected features, incorrect architecture/target,
plaintext/debug/console feature changes or mismatched sealed identity reject
the input. These claims are accepted only under the operator's independent
external pins, not because the JSON asserts them.

The current source producer is `d00a8b97501a2ce1045d579e62568c5feb017ca8`,
tree `2d8e43151b3824bd485090d905a8fdf22a17fc9f`. Required Cargo profile
is opt3/debug0, no debug assertions/overflow
checks/test. Exact features are xodus/CLI empty, management live, native Keychain
and security-framework. The old e7/304 engine cannot satisfy this gate.

The copied unsigned engine is rehashed before signing. The separately signed
CLI/helper identities are new pins, not renamed unsigned hashes. Only then is
`ShippingPairPins.swift` generated and the launcher compiled in the isolated
source stage. The external package receipt records unsigned/provenance inputs,
signed identities, generated compiler pins and final resource/package inventory.
The final app sign is followed by deep verification, helper receipt/identity,
arm64 and C95/provider-resource checks, then the original unsigned inputs are
reverified. Signing/source generation is never performed on the current checkout
or a protected bundle.

## Explicit signing policy

Packaging requires a supplied matching OS Keychain code-signing identity's
exact certificate SHA1 through `--signing-identity`; there is no automatic
ad-hoc fallback. Preflight uses `security find-identity -p codesigning`, not
the trusted-valid-only `-v` filter. A matching local self-signed identity may
report `CSSMERR_TP_NOT_TRUSTED`: this does not require global OS trust for a
fixed-leaf designated requirement. Expired or wrong-purpose error entries are
not accepted. This is not Developer ID, Gatekeeper or distribution qualification.
Signing
identifiers are fixed to `io.github.dragoshont.xodus`,
`io.github.dragoshont.xodus.cli` and `io.github.dragoshont.xodus.auth-host`.
The designated requirement binds the fixed identifier to that certificate's
fingerprint, not a build-specific code hash. The development bundle identifier
and existing preferences are unchanged by this signing-identifier preparation.

An equal designated requirement is not proof of unattended saved-item access
after a locally signed engine rebuild. Apple's securityd also checks a separate
partition: locally self-signed, non-Apple-chain code is classified by its
build-specific code-directory hash. A new build may therefore require a native
human Keychain approval. The app's foreground status read permits that prompt;
verification remains a separate noninteractive read. No arbitrary Team ID,
global trust change or credential reset is used to bypass this distinction.

Certificate creation, trust changes and any private-key permission prompt need
separate human approval. The tooling never creates/unlocks a Keychain, exports a
private key or changes a credential ACL. Preparation and neutral tests are not
proof that a usable identity exists or that saved credentials became accessible.
Before accepting an identity migration, obtain two independently approved build
receipts/runs that each bind an actual build to its signed CLI artifact, and
compare those artifacts:

```sh
python3 tools/signing_identity.py compare --kind cli --identity CERT_SHA1 \
    --first /absolute/first/signed-cli --second /absolute/second/signed-cli
```

The comparison checks valid signatures, different signed bytes and exactly the
same fixed certificate-bound designated requirement. Its result is only
**different signed artifacts share a requirement**: file-hash inequality cannot
distinguish an independent rebuild from signature variation or re-signing the
same binary. Independent build evidence must be approved separately; this tool
does not qualify two builds. Real identity/persistence qualification remains
pending human-approved provisioning, signing and independent build receipts/runs.
Neutral tests are simulations, not certificate, build or persistence evidence.

An explicitly approved UI-only package may preserve its signed engine with
either the same exact stable certificate or explicit `--local-ad-hoc`, together
with the externally pinned prior final package receipt:

```sh
--preserve-signed-cli /absolute/accepted/cli SHA256 BYTES \
    /absolute/prior/package-receipt.json RECEIPT_SHA256 RECEIPT_BYTES
```

The independently approved receipt must bind that exact signed CLI in both its
signed identity and final package inventory, the required producer/tree, and
the same sealed unsigned/provenance approval, profile and features as the current
externally pinned inputs. A hash/size supplied for the CLI alone is insufficient.
The bounded prior receipt is hash-pinned before parsing; missing, changed,
cross-producer or mismatched sealed-input approval rejects reuse before signature
verification or copying. The copied CLI and receipt are verified again after
copying and after the app sign; the engine is never re-signed.
Stable mode also strictly verifies the existing and copied CLI's exact fixed
identifier/certificate-leaf designated requirement against the supplied
certificate before copying and after the final app sign. A different certificate,
identifier, build-cdhash requirement or ad-hoc CLI cannot pass as a stable pair.
The app and helper may be rebuilt without re-signing or changing the CLI bytes.
Preservation alone does not establish credential access or independent engine
rebuild reuse. The receipt's existence or self-asserted contents never replace
independent operator approval of its exact hash/bytes.

Runtime admission requires canonical no-follow current-UID single-link regular
executables, non-group/world-writable files, exact sizes and SHA256; helper
metadata remains bounded/canonical and its source/version/hash must match
compiled pins. The management launch rechecks identity immediately before
execution; paired auth mutations also recheck. Pure planning performs the same
shipping pair gate and prelaunch engine check. No credential value is added to
argv, receipts or logs.

## Evidence and remaining gates

Neutral checks compile the shipping source, test nil/valid/missing/changed/
linked/source/version/size failures with an owned mock engine and no helper or
account operation, verify no shipping resource bundles contain illustrations/
private fixture corpora, and execute the shipping binary's rejected flags.
Startup delayed reconciliation tests protect a post-ready user query across
initial connection and reconnect; loading/error/cancelled/confirmed-zero remain
distinct.

This is a **controlled local operator-approved pair**, not a generic provenance
framework, DeveloperID release, notarized distribution or a successful Microsoft
login. New sealed CLI existence does not authorize packaging/launch. Source
review, exact native qualification, independent package checks, desktop ownership
and explicit launch approval remain separate. Credentials, MFA/consent and
Keychain interaction are human-only. Owned inventory, install/update and verified
gameplay remain unsupported rather than fabricated. No passkey capability or
biometric cause/fix is inferred from the Swift host or neutral tests.
