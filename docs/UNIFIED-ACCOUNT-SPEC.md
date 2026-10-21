# Ode to X: unified account implementation specification

Status: implementation in progress, not shipping-admitted. Scope: one interactive
Microsoft sign-in for games, PC library, Xbox profile and achievements where the
provider authorizes those capabilities. This document does not promise ownership,
downloadability, compatibility or gameplay merely because authentication succeeds.

### Fresh integrated local candidate (21 October, after policy correction)

Subsequent owner-authorized interactive test: the owner explicitly requested
sign-out and offered to complete Microsoft login. The native account sheet's
sign-out confirmation was invoked; the app returned to its one
`xodus.welcome.signIn` action with sign-out no longer available. Starting that
action opened the bundled native auth host. Subsequently the host closed and
the app's account control reported `Microsoft sign-in saved`, with no pending
or welcome sign-in control. No Microsoft login fields, passwords or MFA values
were inspected or logged. An accessibility press on the disappearing sign-out
confirmation returned an error, but the resulting signed-out state was checked
before any retry; sign-out was not issued twice.

Two fresh management processes then passed saved status and noninteractive
runtime authorization with that newly saved session. The independently compiled
update at app source `2a2555305485ddf6de1031b596ebf7747889e639` passed the same
checks in two further fresh processes. Its signed engine SHA256 is
`60ba944a4eff7948fe0d3dd9d225dccb05236ebe78175185bfd43363a23862c9`.
The updated package's enforced native features/profile/architecture checks,
exact file inventory and deep strict signature verification passed. It was
installed at `~/Applications/Ode to X Local Candidate.app`, retaining the first
candidate at `~/Applications/Ode to X Local Candidate Previous.app` and the
original Development app separately. The updated native app reopened with
`Microsoft sign-in saved`, no welcome sign-in action and four local game cards:
the fresh interactive session survived the app/engine update without another
login. Private results are in `Ode-local-dgpbwu58/fresh-signin-restart-results.json`
and `Ode-local-tzoxh7rf/fresh-signin-update-results.json`.
This supersedes the earlier untested interactive/update boundary below, but not
the remaining notarization, reboot/locked-Keychain or gameplay limitations.

The supported `tools/build_local_candidate.py` path built clean app source
`a444f8fe5bb040b9d9d81e4263869385f7118977` with clean engine source
`96d91dbec6727b4a7409908352c48f09411d3508`. The engine was compiled offline,
locked, into a new target directory; actual native features and opt3/debug0
profiles matched the live release configuration. Its signed SHA256 is
`327e4ac76e1e944c8df5d24d3007bc9715e8e7773bac8d260e27bb1d22822fb6`.
The engine's management contract matched the app resource before packaging.
App-specific producer/source and signed engine/helper pins were generated only
in the isolated stage; the original release producer defaults were not changed.

The packaged engine passed saved-account status and noninteractive runtime
authorization in two fresh processes. The integrated staged app then opened
the native Library, showing catalogue content and four local games. A separate
copy at `~/Applications/Ode to X Local Candidate.app` matched all 24 recorded
package files, passed strict deep signature verification, and opened its own
native Library with the bundled engine running. Window-only captures and build/
restart receipts remain private in `developer-id-candidate.27yxwh/Ode-local-dgpbwu58`.
All three executables were verified arm64, hardened and securely timestamped
under the owner's Developer ID identity. The old Development app was preserved,
not replaced; only the new local candidate was left running.

Gatekeeper still rejects the candidate as `Unnotarized Developer ID` (exit 3).
No quarantine/trust bypass, new Microsoft sign-in, credential mutation or game
launch was performed. Accessibility inspection was unavailable; window capture
and exact-process/bundle identity provided the native launch evidence instead.
This is not production readiness or interactive sign-in/gameplay qualification.
After review, the packager also gained explicit Apple Silicon host and all-three-
binary architecture checks; those checks were independently applied to this
already built candidate. Current local policy does not require an independent
human-approved build receipt to authorize this work.

### Developer ID provisioning checkpoint (21 October evening)

The owner completed native Xcode Apple-account authentication and explicitly
authorized certificate creation and candidate signing. Xcode created a valid
Developer ID Application identity for team `M62Z4M5EUY`, certificate SHA1
`410914520BCC840C0125D3826CCF0F247F603321`. The existing unsigned source candidate
SHA256 `723d91c83bd53fad10daca3b7cef99aea551c14e0858a39030301a21268e61f6`
was copied to a separate private stage and signed through the repository's
fixed-identifier/fixed-leaf signing policy. Its signed SHA256 is
`baaec709352ec81e63b8259e729750953511e45610caee5ac0b4e238f7a12ff9`.
Strict signature and designated-requirement verification passed.

This is an engine signing candidate, not a packaged app, notarized distribution,
hardened-runtime qualification, stable team-based requirement migration or proof
of saved Keychain access. The current policy still pins the exact certificate.
The installed app and its self-signed engine were untouched and still passed
strict deep verification. No shipping pins or sealed-input approvals changed.
The owner's subsequent request to revoke "the other" certificate was ambiguous
between an older Apple Development certificate shown by Xcode and the local
Xodus identity; neither was revoked or removed without identifying the target.

The subsequent foreground `auth.status` check on that Developer ID candidate
returned `ok: true`, `state: credentialPresent`. Its initial attempt was
refused with `STATE_LOCKED` because the running preserved app owned the state;
the app was quit normally, the check was repeated successfully, and the
preserved app was reopened. No credential values were printed, no Microsoft
sign-in or game was started, and no credential ACL/trust was changed by tooling.
This supersedes the earlier unconditional saved-status denial for this new
signed artifact. It does not establish noninteractive credential access,
live package licensing, game execution, or shipping admission.

### Developer ID manual-approval scenario recheck

The owner requested rechecking the previously manual-approval scenarios. With
the separately signed candidate above, these real checks subsequently passed:

| Scenario | Observed result | Evidence boundary |
| --- | --- | --- |
| Use the new signing private key | Repository signing and signature/requirement verification completed | Does not establish future absence of private-key approval dialogs |
| Read the existing saved account | Foreground status returned `credentialPresent` | Not a new Microsoft sign-in; no credential payload printed |
| Noninteractive package-license access | Abiotic Factor qualifier exited 0 after authenticating its content key | Key not printed/saved; no Wine or game started |
| Restart the same signed engine | Two separate fresh management processes each returned `credentialPresent` and passed `ode.runtime.verify.v1` | Verification uses noninteractive read-only credentials; no new Microsoft login |
| Update to an independently rebuilt engine | Subsequently passed saved-account/runtime checks; see below | A distinct compilation was tested, not another signature of the same binary |
| Reboot or locked-Keychain access | Not tested | No system lock/unlock or reboot performed |
| Gatekeeper / notarized app first launch | Not tested | Candidate is an engine, not a hardened/notarized admitted app package |

The preserved app was normally quit to release its state lock for these checks,
then reopened. A private closed-result restart receipt contains only scenario
outcomes, not account IDs, credential values or provider payloads. The earlier
blanket native-password blocker is resolved for the observed candidate paths;
do not keep reporting it as their current outcome. No claim is made that
Developer ID removes all macOS prompts, or that a human never interacted with a
foreground native dialog. The noninteractive successes are the narrower proof.

### Extended approval regression results (21 October)

The owner's exhaustive recheck added an offline release compilation of clean
runtime source `96d91dbec6727b4a7409908352c48f09411d3508` into a new empty
target directory (not a second signature of the original file). Build ran
19:48:26Z-19:49:15Z. Its unsigned SHA256 was
`ce6d10de182920e11d75fc5523797afd0a9629fa039e6536f1580ad70bc8e460`;
Developer ID signing produced
`45033eebdd22c468c179abe27c07a2ddd483be5e4496ead77c0fbcb0cc4f4414`.
Both different artifacts passed the fixed-certificate designated-requirement
comparison. These observations establish the measured local rebuild behavior,
not production readiness; see the corrected local policy in SHIPPING-ADMISSION.

Observed live results:

- The freshly compiled signed engine passed saved status and noninteractive
  runtime authorization in two fresh processes.
- It also passed noninteractive Abiotic package qualification (authenticated
  key, no key output/persistence and no game), followed by another fresh-process
  runtime verification.
- Relocating the original signed candidate to a new owned directory preserved
  its signature and passed two fresh-process account/runtime checks.
- Returning to the original installed self-signed owner also passed two
  fresh-process account/runtime checks; rollback access was retained.

Negative/release boundaries remain explicit. `spctl --assess --type execute`
rejected the candidate with `source=Unnotarized Developer ID` (exit 3).
The default local signing mode disables secure timestamps and hardened runtime;
the later explicit Developer ID mode enables both. The created certificate alone
does not make either artifact a distribution-ready binary.
Its observed public certificate validity is 21 October 2026-1 February 2027.
No notarization credentials were provisioned or extracted from Xcode.

The full documented `tools/check.sh` also exposed an existing package-resource
admission mismatch: `verify_shipping_package.py` expects management schema
SHA256 `d2f4222e952f732396018a4c4576da24729bdbddde7dd1f95df3b84d7a6d324d`,
but the checked-in contract and resource both contain
`03afeb28e4e5b652712c2b6f29fe648fa05c842ea86a4920bd4f960bdbcc0529`.
The matching runtime-provider schema remains unchanged. The mismatch dates to
the earlier management-contract changes; sync did not modify tracked bytes.
The verifier's rejection was preserved, not hidden by replacing an approval
hash. Remaining regression checks were invoked separately to expose other
failures rather than stopping evidence collection at that first rejection.
Those remaining checks all passed: private Python-runtime packaging checks,
shipping XCTest/binary-admission checks, fixture and management executables,
presentation and synthetic native-session checks, auth-host checks and
credential-wire checks. The affected CLI/service/management Rust suites passed
223 tests with two explicitly ignored tests (one pre-existing CLI test and the
external-checkout integration test, which had previously been run explicitly).
These regressions do not override the real package-schema rejection.
Reboot/locked-Keychain, a real upgraded app package and notarized first launch
remain untested; the Mac was not rebooted or locked remotely.

Follow-up trace clarified the schema rejection: the earlier description
"stale" does not establish that its pin may be updated. NATIVE-INTEGRATION.md
binds the `d2f422...` schema to approved producer `28f737df...`, while
BACKEND-CONTRACT.md explicitly says the later account/runtime extensions are
not admitted by that producer. Commits `bd1725e` and `13f3532` introduced those
extensions and explain the different checked-in bytes. The rejection therefore
exposes an unresolved producer/consumer admission boundary. Changing that hash
alone would not admit this candidate; exact new producer/source/provenance
approval and matching generated package pins remain necessary.

### Current implementation boundary

Distribution-signing tooling now has an explicit `sign --developer-id` mode:
it requires a valid Developer ID Application identity, requests Apple's secure
timestamp and enables hardened runtime without adding permissive entitlements.
Default local signing is unchanged. A separate candidate signed in that mode
passed strict verification; metadata showed `flags=0x10000(runtime)` and a
secure timestamp. SHA256:
`d18d7009c06411c98a5913211d6ffc0ebdd8fb8832c94569331ee315f6ab4f3a`.
Two fresh processes again passed saved status and noninteractive runtime
authorization. This verifies those hardened-engine paths only, not native
interactive sign-in UI, package/game execution, notarization or an app package.
The installed preserved app was reopened afterward. No shipping pin changed.

The first source slice adds `ode.account.read.v1` to the paired Rust producer
and native client. Library collection, profile and per-title achievements derive
authorization from the isolated launcher session, with bounded reads and
generation/publication checks. Swift resolves collection IDs through the existing
public PC catalog path without receiving tokens. Native synthetic checks exercise
empty collection, denied access, mismatched identity and late retirement.

This is **not full single-login acceptance**. The installed private game scripts
still use the global service and another CLI; they are not rerouted by this
slice. The new native route therefore disables those credential-dependent game
operations and exposes the runtime update requirement instead of silently falling
back or offering another login. Friends/consoles remain explicitly unavailable
on that route. Provider eligibility, real audience authorization, saved-session
refresh/persistence and a paired runtime consumer still need qualification.

The next source slice adds `ode.runtime.verify.v1`: fixed, silent MSA runtime
authorization from that same management session, returning only an account-bound
boolean. `ode-runtime --socket` serves the existing isolated RPS protocol using
read-only, noninteractive management credentials. Its ready frame proves binding,
not authorization; its inherited parent descriptor fences lifetime and joins
peers on EOF. The native session verifies authorization, supervises that private
broker and stops it before logout/disconnect. No default/global service path is
substituted. Installed game-script and Wine-consumer pairing remain separate.

The live post-reset diagnostic confirmed a saved management account and a
successful profile read, while collection failed with `profileChanged`. The
candidate now derives Xbox and Store XSTS from one shared user-auth token rather
than joining independently issued authorization chains by `uhs`. Verified Xbox
XUID and any conflicting Store XUID remain checked. Native account-read errors
retain the typed failure stage instead of collapsing into generic `AUTH_INVALID`.
Follow-up private live checks succeeded for collection, profile, a real recent
title's achievements and runtime authorization using the same saved session,
without another interactive login. The private runtime also returned valid
user/device RPS tickets to a scoped local test consumer and cleaned up on parent
EOF. Account payloads, identifiers, tickets and title details are not committed.
This proves those scoped auth/read paths, not populated PC ownership, installed
game-consumer pairing or gameplay.

**Local AAA qualification checkpoint (20 October):** The registered No Man's Sky
7.6 installation contains an encrypted MSIXVC-backed executable, not a directly
launchable PE file. A source-owned, noninteractive package-license qualifier was
added separately to the writable producer; it neither starts a game nor exports
keys. The rebuilt qualifier was refused access to the isolated saved session by
macOS (`accessDenied`, OSStatus `-25293`), while the preserved signed producer still
reads that account and passes runtime authorization. Session 2 confirmed a native
login-Keychain password prompt for the qualifier; the owner's approval of
experimentation does not supply that password. No Keychain ACL/trust
change, legacy-account fallback, package-key copy, or opaque private-service
protocol substitution was performed. Session 2 subsequently recovered the modified
legacy source implementing that consumer at fork ref `private/ai-hogwarts-runtime`
(`7ae8ffe`). Its package-key
consumer remains separate from the isolated management account; exact
build-to-source provenance of the preserved installed binary is still unresolved.
A real registered NMS launch failed before Wine with `entry not found` hidden
by an empty service response. The isolated legacy diagnostic patch `0c3cbb3`
now preserves typed credential/request failures, with focused tests and local
release builds; it has not replaced the installed service or integrated the
management account into that consumer. See [Session 2 evidence](GAME-ENGINE-TESTS.md).
Gameplay and main-branch acceptance are not claimed.
The locally installed UI update preserves the previously verified signed engine
bytes rather than replacing them with the denied qualifier.

**21 October source-only consumer follow-up:** Unified fork `0ccd528` adds
package-key frames to the existing private broker, enabled only by an explicit
`ode-runtime --package-account-hash <exact-account-hash>` selection. The default
broker has no license provider. The selected provider rejects legacy profiles,
checks the exact saved account, passes that same checked credential snapshot to
the existing license acquisition code, authenticates the one packed content key
and rechecks the profile before returning it over the private socket. Keys never
enter management JSON, logs or disk. Failure is a closed nonempty error frame.

The modified staging consumer at `bc3afab` accepts `XODUS_LICENSE_SOCKET` only as
an explicit owned private socket, with no global fallback on invalid selection.
The generic launcher preflight and RPS bridge inherit that same endpoint.
An explicit endpoint without service-backed licensing is rejected before
credential initialization. Omitting the selection retains the legacy endpoint.
This removes a source-level pairing gap; it does not qualify the native app,
all game-shim protocol calls, live package licensing or actual game launch.
Local release builds and memory-only protocol/lifecycle checks passed. The
installed signed pair and its Play gate remain unchanged, pending native
credential permission, live verification and shipping admission.

Follow-up `f5fe973` corrects the separate package qualifier: counting a single
packed key is insufficient to report verification. The qualifier and private
broker now share authenticated single-key unpacking. Synthetic checks cover
missing/multiple keys, invalid wrapping, a valid wrapped key and the wrong device
key. No live qualification was retried or inferred from these fixtures.
Cancellation follow-up `0e63cd4` exercises an in-flight package provider through
the real Unix-stream router: cancelling the parent request drops the pending
provider and closes the socket without publishing a key frame.

Follow-up source `3bc6599` adds the recovered game shim's XML license-token
bridge (7/8) alongside MSA tickets (3/4) and opted-in package keys (5/6).
The token route uses the same exact-account option and checked noninteractive
snapshot, with shared device/user ticket acquisition, bounded flat XML,
closed failure behavior and cancellation without late secret publication.
Synthetic actual Unix-stream framing, missing provider, repeated products,
empty custom text and signed-out/legacy-profile refusal are checked.
This is not live game-shim compatibility or permission to enable native Play
or promote a package. The owner was unavailable for the genuine native-password
checkpoint; it was not retriggered or bypassed.
The actual recovered C shim emits an XML declaration and escaped developer
text. A reproduced rejection of standard character references was fixed in
unified source `b7382f2`; built-in/numeric references now pass, while unknown
entities and DTDs remain blocked. Consumer `4bf453c` validates explicit private
endpoint ownership, canonical parent, permissions and socket type before
starting Wine, then rechecks before forwarding each request. Synthetic
authenticated TCP-to-Unix transport preserves the shim-shaped 7/8 frames.
These transport and service checks are separate fixtures, not a live combined
provider/shim/game result.
The subsequent explicit cross-checkout run (`96d91db` / consumer `2170338`)
also passed the actual Python capability bridge into the real isolated socket
listener/XML router with an injected memory-only provider, and verified the
synthetic token plus joined cancellation/socket cleanup. This closes the
combined synthetic transport check, not live credential/provider/Wine/game
qualification. The external-checkout test is explicitly ignored by default
and was executed separately; it is not silently counted as a default pass.

The supported preserved-engine path was also exercised specifically for No
Man's Sky: its declared MSA client `000000004826ED21` obtained unexpired silent
user/device tickets through the isolated broker, and `auth.verify` accepted its
actual content ID through the authenticated package-metadata provider. The
broker's owned socket was removed on parent EOF. These are distinct game-identity
and package-read proofs, not a content-license key acquisition, consumer pairing
or observed game process; no legacy credential source or game start was used.

The existing default Xodus login and credential stores are unchanged. The new
Rust readers live in product-owned `ode_account` modules; management wiring and
the schema generator are the integration hooks. The native route is selected
only when the paired engine advertises the explicitly versioned operation.
The source candidate producer is
`261690eafbb21ce2368caccc64109676930476da`, tree
`690491b2cb6ffa588798f9bda9e8864a1ebf5fa6`; it is committed locally in the
writable `ode-unified-account` fork worktree, not pushed or substituted for
the approved sealed shipping input.

## Decision and repository boundary

Changes are required in **both repositories**. Ode to X is the native product in
`xodus-macos-app`; its forked Xodus Rust producer is the authentication/runtime
implementation. Authentication unification belongs primarily in that fork, not
in Swift views, and does not require changing upstream Xodus itself.

The proposed smallest durable architecture extends the existing management
credential owner and authenticated-read pattern through isolated Ode to X
modules. Do not create a fourth vault, an independent login server or a new
browser-based frontend.

### Upstream-update constraint

Keep original Xodus behavior and default build paths unchanged wherever
possible. Put product-specific account orchestration, provider adapters and
wire-contract extensions in separately named modules or crates in the fork.
Reuse upstream libraries through their existing public APIs first; do not copy
their authentication implementation into a parallel maintained version.

Use this order of preference:

1. Additive Ode to X modules using existing public extension points.
2. A small, explicit integration hook in an upstream-owned module when its API
   cannot express the required credential source or lifecycle fence.
3. A narrowly scoped upstream-code change only when the first two cannot
   preserve correct authorization, cancellation or runtime behavior.

The ownership table below identifies functional seams, not permission to spread
Ode to X logic across every listed original file. Keep account policy in the
additive modules; original files should contain only necessary wiring. A
separate Rust crate is justified only where actual API/build boundaries warrant
it; a product-specific module is sufficient otherwise. Swift remains a consumer,
not a workaround credential owner.

Select this integration explicitly in the paired Ode to X build. An ordinary
upstream/default build must retain its existing login, storage and service
behavior. The new path must never silently fall back to legacy authentication.
Do not migrate, delete or repurpose original Xodus/global credentials as a side
effect of enabling Ode to X. Legacy removal remains limited to explicitly
identified app-owned sessions under the migration contract below.

Zero changes to original files is a goal, not an established capability. In
particular, runtime token consumption may require a credential-provider hook.
Trace that seam before choosing an in-process adapter or private IPC; a wrapper
cannot make a service use a different authority if the service has no such API.
Do not use monkey-patching, binary patching or credential copying to claim
upstream independence.

Keep any unavoidable hook patches in separate focused commits from product
implementation. Document the upstream base, touched upstream seams and reasons
in the fork's integration documentation. For each upstream update, verify both
the unchanged default path and the paired Ode to X path, including contract
compatibility and auth lifecycle regressions; passing a clean merge alone is
not compatibility proof. Do not add an automatic updater or enable Actions as
part of this work.

| Owner | Required changes | Existing seams |
| --- | --- | --- |
| Forked Xodus, `crates/xodus` | Account-session authority, audience-specific authorization, refresh, account/generation fencing and service credential access | `tokens/manager.rs`, `tokens/backend/keychain.rs`, `auth.rs`, `api/xbox` |
| Forked Xodus, `crates/xodus-management` | Negotiated account/capability snapshot, operation authorization, explicit recovery and coordinated logout contract | `adapter.rs`, `wire.rs`, `auth_verify.rs` |
| Forked Xodus, `crates/xodus-cli` | Library/profile/achievement adapters using that authority; retain existing native issuance and lifecycle controls | `management_auth.rs`, `provider_credentials.rs`, `recent_library.rs`, `commands/login.rs` |
| Forked Xodus runtime/service and private-script producer | Consume scoped authorization for the selected account; report unavailable/expired/transport failures distinctly; retire independent interactive login in the paired route | Current `xodus-service` IPC and `private-xodus-manage.py`; exact producer module for installed social helper remains to be located |
| Ode to X, `Sources/XodusManagement` and contracts | Typed consumer of the new negotiated contract, no credentials | `WireModels.swift`, `ManagementClient.swift`, `ContractValidator.swift`, canonical schema/resources |
| Ode to X, `Sources/XodusPreview` | One account coordinator, capability-based access, honest partial states, accessible layout and branding | `AppState`, `LiveSession`, `LiveRootView`, `PCGamesController`, `GameOperationsController`, `XboxCompanionController`, Account/Welcome views |
| Ode to X packaging | New exact producer pairing, component identities and admission evidence | `tools/build_app.sh`, shipping pins, helper/broker manifests, shipping documentation |

The sealed producer snapshot `28f737df46b29cc195145425e3fd1397ebc09be3`
is read-only evidence, not an implementation checkout. Implement Rust changes
in a writable fork worktree; seal a new producer only after verification. The
current app baseline is `8586a38dc98833f761201db8b5690ecb6ebc3a63`.
An unchanged preserved CLI can package UI fixes, but cannot deliver this contract.

## Adversarial correction of the audit

| Finding or assumption | Evidence and qualification | Consequence |
| --- | --- | --- |
| Three authentication paths exist | Management uses an isolated management store; PC library uses client `1f907974-e22b-4810-a9de-d9647380c97e` and its broker; service login uses a separately installed CLI and global store | A successful management login does not initialize the other paths |
| A bootstrap cycle can strand first-time users | `LiveRootView` requires matching management/library/service plus a returned profile; `PCGamesView` owns missing-library sign-in inside gated content | Prove reachability from empty stores; do not merely remove the visible second button |
| One saved session can serve everything | Not established. `recent_library.rs` demonstrates a management-owned authenticated TitleHub read in source; it is not a live proof of full collections, profile, achievements or runtime audiences | Audience feasibility is the first implementation gate |
| Same client ID means credentials can be shared | False. Client IDs do not establish storage authority, matching account, token audience or consent | No opaque-token copying or fallback to unrelated global credentials |
| Service says false, therefore user signed out | Not established. Installed `service_signed_in()` maps transport/parse failures to false | Preserve failure cause; do not respond to a connection fault by launching consent |
| The service account hash proves the consuming service identity | Not fully established: installed status obtains identity using a separate social helper/cache | Trace that helper's credential owner and bind the actual consumer; cache identity alone cannot authorize games |
| Profile failure means authentication failure | False. The current root gate requires profile availability in addition to identity | Profile/network/privacy failures must be separate from verified account identity |
| Removing the profile gate solves login | False. It could expose cross-account cache or operations without authorization | Replace with per-capability authorization and account-scoped data fences, not an unconditional unlock |
| One login eliminates macOS prompts | False. Keychain access approval and Microsoft consent are separate; rebuilt self-signed code can prompt again | Preserve native approval; qualify stable-owner persistence separately |
| Layout alone explains every hidden item | Only the inspected 480-point sheet and its below-fold controls are confirmed | Verify the corrected screen and keyboard/VoiceOver paths, not just frame constants |

The previous explicit-service-action patch was a stopgap, not an implementation
of one login. The existing `do_sisu` machinery is a feasibility lead, not a
ready-made universal exchange: it reads particular token roles, can persist
tokens, and contains failure paths unsuitable for blind production reuse.

## Product contract

1. An initially signed-out user chooses **Sign in with Xbox Live** once.
   Microsoft may require multiple pages, MFA or consent within that one owned
   flow. The app must not initiate independent library/service login flows.
2. After identity establishment, the backend silently prepares only authorized,
   approved audiences. A provider request for additional consent is an explicit
   capability state, not a hidden browser launch or successful completion.
3. Readiness is reported per capability. If a required audience cannot be
   obtained from the selected session, the single-login requirement is unmet;
   do not call the result unified or production-ready.
4. Games/library may open once their account identity and applicable read
   authorization are verified. Optional profile, friends, gamer picture or
   achievement failure must not lock the entire shell. This intentionally
   supersedes the all-identities-plus-profile gate in `UX-FLOWS.md` only when
   the replacement backend contract and data fences are implemented.
5. Install and launch retain their separate entitlement, package, runtime,
   compatibility and operation guards. A signed-in account never implies access.
6. Display name is **Ode to X** throughout app-owned surfaces. Keep bundle,
   executable, signing, Keychain, filesystem and protocol identifiers unchanged.
   Do not alter Microsoft-hosted branding or substitute client registrations.

## Backend session and authorization contract

Extend the existing management protocol through an explicitly negotiated,
schema-pinned revision. Names below describe proposed semantics, not commands
that the present producer accepts. Set the exact wire names/version and update
both canonical schemas before implementation; old strict 1.0 clients must not
receive new fields they reject.

The account snapshot carries:

| Field | Requirement |
| --- | --- |
| `state` | `signedOut`, `authenticating`, `establishing`, `active`, `reauthRequired`, `signingOut`, `removalIncomplete` |
| `sessionID` / `generation` | Nonsecret opaque session identity and monotonic account-lifecycle generation; distinct from transport session/request sequencing |
| `accountHash` | Existing validated domain-separated account hash, absent until backend identity verification; never an email-based join |
| `capabilities` | Separate entries for PC collection read, profile read, achievements read and runtime authorization; each has `unavailable`, `checking`, `ready`, `consentRequired`, `reauthRequired` or `failed` |
| freshness | Per-entry observation time and expiry when known; unknown expiry is not infinite freshness |
| reason | Bounded typed stage/category, retryability and recovery action; no tokens, signed URLs, raw provider bodies or personal identifiers |

The snapshot is advisory for presentation, not a bearer capability. Every
authenticated operation rechecks the current generation, account, audience,
expiry and relevant authorization before execution and before publishing data.
Status reads never initiate consent. Coalesce refresh per session/audience;
bound deadlines and retries; authentication rejection, network failure,
rate-limit and malformed response remain distinguishable.

Reuse `ProviderCredentials::read`, its bounded credential IO, and
`verify_current`/publication-witness pattern where appropriate. Extend this
pattern to profile and collection results instead of trusting cached equality.
All provider adapters must validate returned subject against the selected account.
Each audience has a documented endpoint, client registration, scopes/relying
party, subject extraction, refresh mechanism and provider-policy basis. No
generic caller-supplied audience, arbitrary URL or token-export operation.

### Runtime boundary

The runtime consumes a least-privilege account-bound authorization through a
private authenticated local channel. Choose the minimal extension of the
existing service IPC after tracing its producer; authenticate the intended
consumer, not merely a socket pathname or claimed account hash.
The socket server's exact producer module and peer-authentication/lifecycle
behavior also remain to be traced; the installed client script alone does not
establish those properties.

The durable credential remains owned by the backend credential authority.
The native UI never receives access/refresh/STS/XSTS tokens, device secrets or
raw credential handoffs. Retain the existing isolated native auth host boundary.
If the runtime requires tokens in memory, restrict them to the necessary
audience/consumer and lifetime. No argv, logs, world-readable files, generic
token socket or Swift cache.

Fence runtime refresh/publication with account generation. Logout/account
switch invalidates issued grants and fences old requests; obtain consumer
acknowledgement or stop/reconcile the consumer before claiming removal.
After a crash/restart, a retained service session must be reconciled with the
current authority before use. An old in-memory token must not resurrect a
retired account. Preserve current running-game/mutation holds.

### Persistence and migration

Retain one authority for new sessions. Use the existing management storage seam;
do not silently broaden the PC-library broker, which currently owns only one
library refresh token. If stable credential-helper ownership is required for
update persistence, specify and independently qualify its narrowly scoped
signed-peer contract before extending that component.

Legacy stores are not imported merely because account hashes or emails appear
equal. A legacy user may need one explicit sign-in to establish the new session.
Until it succeeds, leave old stores untouched and report upgrade requirements.
No background credential reads, migration or deletion under this specification's
documentation work; live qualification requires the user's credential actions.

Migration is staged and idempotent. Persist a nonsecret phase/generation record
for crash recovery; never secrets in that record. Establish the new authority,
verify required capability subjects, then retire only app-owned legacy sessions
through existing acknowledged removal paths. Failure retains a truthful partial
state and retry point. Switching or signing out fences data immediately even if
credential deletion fails. Full logout requires all applicable credential and
consumer-removal acknowledgements. Device licences, games, saves and other apps
are not deletion targets.

Rollback must preserve recoverable credentials and prevent dual authorities:
do not run old and new producers concurrently or allow the old service to
consume a retired session. If an older version cannot reconcile the new state,
require explicit recovery rather than silently presenting stale login success.

## Native implementation

`AppState` coordinates user intent and one observed backend account snapshot;
`LiveSession` owns connection and typed account lifecycle. This is not a new
credential manager in Swift. `MicrosoftSignInGate` and existing mutation/Quit
holds continue to serialize explicit interactive work.

Replace independent OAuth initiation/refresh in the shipping PC-library path
with the management collection operation once it exists. Retain paging,
completeness, market/language, product identity and stale-data semantics; never
replace a full PC collection with TitleHub recent history. Replace
`GameOperationsController.signInForGames()` in the paired route with scoped
backend preparation/status, not installed CLI `login`. Move companion fetches
onto the same verified account contract or a paired bound backend adapter.

`LiveRootView` derives shell/data access from account and relevant capability,
not profile existence. Fence caches, in-flight tasks, installed-game disclosure
and operation admission on account switch/logout/failure. Cached content may be
shown only under explicit same-account stale-read policy; it never authorizes
new mutations. Preserve generic recovery for an already-running operation.

Account/Welcome requirements:

- One brand mark, app name **Ode to X**, one primary sign-in/recovery action.
- No Xbox-logo placeholder beneath the app logo; gamer picture only when real.
- During establishment: say what is loading without claiming all access ready.
- Missing/failed profile: distinguish loading, offline, privacy/authorization and
  request failure; do not say the Xbox profile does not exist without evidence.
- Required action and current problem visible at the minimum supported sheet
  size, including the observed 480 x 480 points. Put optional detail in scrolling
  content; keep primary action/cancel in the fixed reachable action area.
- Native keyboard navigation, VoiceOver order, wrapping, light/dark appearance,
  safe resizing and normal Quit remain usable.

## Delivery gates and acceptance

### 1. Audience feasibility before broad refactoring

Build a bounded producer-side vertical slice for the existing management
session: verify account identity, full PC collection (not recent history),
profile, one achievement read and runtime authorization. Record only redacted
stage/result/subject-match evidence. Exercise the real runtime consumer, not
just a helper's independent credential cache.

Use synthetic/saved-response tests first. Human-assisted live testing uses one
explicit sign-in, no automated credential entry, Keychain approval or game
launch. If a required provider audience needs a separate incompatible login,
stop and revise the architecture with that exact evidence. Do not hide it behind
a second "Continue" button. Confirm client-registration/endpoint-policy
eligibility; technical exchange success alone is not distribution permission.

### 2. Contract and implementation

Land paired producer/schema/client changes locally, preserving existing native
auth lifecycle and bounded IO. Retire the old interactive paths only in the
paired Ode to X route after the new vertical slice passes parity; retain
original Xodus default behavior. Add per-capability state and update
`UX-FLOWS.md`, `BACKEND-CONTRACT.md`, `NATIVE-INTEGRATION.md` and shipping pins
at implementation time; historical docs must not claim the proposal shipped.

### 3. Required adversarial cases

| Case | Required result |
| --- | --- |
| Empty stores, normal login | Exactly one app-initiated interactive flow; matching real PC library/profile/achievement/runtime authorization, no service/library login |
| Restart with saved session | No interactive Microsoft flow when refresh is allowed; current same-account reads work; Keychain approval counted separately |
| Expired/revoked account | Correct typed recovery; no repeated consent loop or false signed-out classification from a transport failure |
| Profile unavailable, library authorized | Library remains usable; profile shows its actual partial failure |
| Library audience denied | No fabricated owned list; explicit scoped failure; single-login acceptance fails if this requires independent login |
| Provider no-games response / paged failure | Empty collection distinct from incomplete read; no replacement by recent activity |
| Account A -> B during refresh | A results/caches never publish into B; old grants and runtime requests fenced |
| Logout during refresh / partial removal / process death | No resurrection; restart reconciles partial state; no success until required acknowledgements |
| Old service or missing negotiated contract | Truthful update-required state; no fallback to separate interactive login |
| Original/default Xodus build | Existing auth/storage/service behavior retained; Ode to X modules inactive and no implicit credential migration |
| Upstream update | Default-path regression and paired-path contract/lifecycle tests pass; hook changes explicitly reviewed |
| Offline, timeout, throttled or malformed response | Bounded retry policy and specific stage; no new consent or destruction of unrelated state |
| Concurrent clicks/windows/foreground events | One flow and coalesced preparation; cancellation joins owned children |
| Update across independently built signed engines | Saved-credential access qualified without assuming equal signing requirements eliminate Keychain prompts |
| 480-point sheet, keyboard and VoiceOver | Primary action and failure visible/reachable; no duplicate mark or clipped mandatory controls |

### 4. Local delivery and readiness claims

Commit locally; do not push or enable/dispatch the manually disabled Actions
workflow. Run existing targeted native/protocol/producer checks and a shipping
compile; add deterministic regressions for the cases above. Package with a newly
sealed verified producer and exact paired approved inputs, preserving signing,
provenance, credential-host and runtime checks. A changed producer cannot reuse
the old sealed engine identity or be described as a UI-only preserved-CLI build.
Open the fresh local app for user testing, without clicking consent or launching
games. Record the exact app path and what remains unverified.

One-login acceptance requires observed human-assisted completion and restart
on the exact paired build. It is separate from full production admission,
distribution signing/notarization, provider eligibility and gameplay acceptance.
No compile result, synthetic check count or successful package substitutes for
those outcomes.
