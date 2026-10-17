# Proposed management contract v1

**Scoped producer/client implementation now exists; the complete game lifecycle remains a proposal.** The pinned canonical schema and actual client/provider evidence are in [native integration](NATIVE-INTEGRATION.md). The sections below retain the full intended lifecycle requirements; they do not claim that gated inventory/install/launch/update operations succeed today. Runtime `xodus-service` IPC is separate.

Stable handoff: **protocol 1.0**, [canonical scoped JSON Schema](contracts/management-v1.schema.json), [implementation ledger](IMPLEMENTATION-LEDGER.md). The [original foundation proposal](contracts/foundation-v1.schema.json) is preserved. The producer fills strict operation schemas for implemented public-catalog/registry/activity/diagnostic operations and explicitly gates game lifecycle success. Native clients validate the expected command's result, not any success-shaped object. A future minor/operation extension needs its own agreed schema/consumer pin; never guess forward compatibility.

## Transport and negotiation

Current scoped entry: `xodus-cli manage --protocol 1 --state-dir <absolute-private-directory>`, one JSON request per stdin line, one JSON response/event per stdout line (UTF-8, LF). stderr is redacted human diagnostics, never machine results; the native client drains/discards it. No interactive prompts. Max frame size 1 MiB; strict 1.0 rejects unknown envelope/parameter fields and incompatible versions. Never place credentials in argv/stdout/stderr. Backend-owned native authentication keeps its credential handoff separate.

Authentication reuses the backend's existing macOS Keychain token abstraction as a single credential owner. Shipping manifests must disable `key-chain-file`/`.xodus-keyring.ron`. Hello must also expose non-secret **per-capability audience requirements**; the broker obtains scoped proofs for inventory/catalog/package/launch as required. Existing Xbox Live scopes and configurable XSTS relying party do not authorize arbitrary inventory APIs.

### Separate private Swift authentication host

This is not a public management-protocol extension. The immutable private-host
contract is producer
[`bb6397033fc38497a73684a9ecdb2929caba1f63`](https://github.com/dragoshont/xodus-macos/blob/bb6397033fc38497a73684a9ecdb2929caba1f63/docs/NATIVE-AUTH-HOST.md);
its exact schema LF SHA256 is
`c7ca7de8ee8a610b71e9e458f13469554467dd2632f88d35317a1ce2646af430`.
Public sanitized schema/fixtures are copied into `XodusAuthHost/Resources`,
not private source or a credential cache.

The Rust worker launches the reviewed bundled Swift executable on an inherited
anonymous duplex FD0. A four-byte big-endian length precedes each UTF8 JSON frame,
with **1..262144 bytes including the entire JSON envelope**. Version1,
canonical flow UUID/session1, exact directional sequences/correlation and
closed field sets are mandatory. Commands are open, at most four navigate
continuations and close; results are ready, exact-seven-string DA, closed,
cancelled or a closed static failure reason. Ready means an accepted native view,
not authentication. The existing inline URL, user agent, nine headers,
getContext callback and issuer strings are retained, not replaced by OAuth
or guessed platform flags.

Only nonsecret all-or-none launch flags cross the main app/engine boundary:
`--native-auth-host <absolute-owned-path> --native-auth-host-sha256 <sha256>
--native-auth-host-version 1`. Wrong/missing required pairing fails closed;
there is no PATH/Wry fallback in the new paired path. Main app frames stay C95.
Swift owns the window and WebKit callbacks; Rust retains proof/SOAP and atomic
Keychain commit. Parent EOF cancellation must fence issuance through helper
close/ack/EOF/exit and final handoff write. Normal engine write-half retention
until worker EOF avoids misclassifying complete publication as premature death.
Those paired backend changes, retained review and deployment require separate
gates; local Swift synthetic tests do not establish that they have shipped.

First request:

```json
{"kind":"request","protocol":{"major":1,"minor":0},"requestID":"req-001","command":"hello","params":{"client":"xodus-macos-app","clientVersion":"0.2.0"}}
```

```json
{"kind":"result","protocol":{"major":1,"minor":0},"requestID":"req-001","ok":true,"data":{"protocol":{"major":1,"minor":0},"backendVersion":"fixture","runtimeFingerprint":null,"capabilities":[{"command":"inventory.snapshot","supported":false,"audience":null,"reason":"Authoritative PC inventory is not established."}],"sessionID":"fixture-session","schema":"urn:xodus:management:1.0","catalogCorpus":"observedPublicProducts"}}
```

This example is synthetic, not runtime certification. Capability entries are typed objects, not strings; a null runtime fingerprint is not a pretend version. Major/minor/schema mismatch or failed hello disables integration with an explicit update instruction. Unsupported operations remain disabled without disabling supported read-only catalog functions. Never assume pause, offline launch, delta updates or rollback just because an engine is present.

## Commands and ownership

`xodus runtime-plan` is a **separate configuration-only route**, pinned to public
producer `9ef0f298481fb48840734b538e0f6d22e1c98ff3` and namespace
`urn:xodus:runtime-provider-configuration:1`; it adds no management operation.
The [provider contract](RUNTIME-PROVIDERS.md) defines explicit stdin EOF and
required nullable fields. Native consumption caps input at 16,384 bytes, stdout
at 32,768 bytes and discarded stderr at 8,192 bytes, with a five-second default
deadline. Exactly one JSON line and clean exit zero are required; all stdout
is discarded on nonzero/signal/error. Extra/duplicate/wrong-type fields, a
different configuration, mismatched generation/path/digest, evidence promotion
or launchable=true are rejected. An older engine reports planning unavailable;
there is no synthetic success, provider probe or auth fallback.

The exact implemented parameter/result shapes are in the canonical schema, not inferred from this forward-looking table. The scoped producer supports public-product metadata/search, catalog-refresh jobs, management-only registry snapshots and redacted diagnostics; sign-in uses separately agreed backend-owned native flow metadata. `auth.logout` takes `{}` and confirms `signedOut` only after successful launcher-profile disconnect; device retention must succeed before user removal. CLI/other-app profiles are separate, never implicitly imported or removed. No successful game-install/launch/update object is promised by the scoped implementation.

| Command | Required input | Result/behavior |
| --- | --- | --- |
| `auth.begin` / `auth.cancel` / `auth.status` | account scope, request ID; cancellation target | Approved consent flow metadata/status only; credentials delivered to broker/Keychain, never events. Nonempty valid credential proof required. |
| `inventory.snapshot` | account scope, market, refresh policy | products + entitlement evidence; source, checkedAt, lastCompleteAt, completeness, cursor/error. Backend consumes all pages or explicitly marks partial. |
| `catalog.search` | query, PC platform, market, language, cursor | Observed public-products cache title search only; partial, not full Store search or inventory. |
| `catalog.discover` | market, language, limit, opaque cursor | Bounded public PC Game Pass candidates, explicit per-product failures, partial coverage; no entitlement inference. |
| `catalog.query` | exact nonblank query, market, language, limit 1..16, opaque q1 cursor | Partial public Store network search with source-backed PC metadata; exact scope/query echo. Genuine zero-source success and strict all-failure error are distinct; leftover source positions cannot be skipped. |
| `product.detail` | product/edition ID, account scope | independent facets + provenance/time/fingerprint; selected package or explicit ambiguity. |
| `install.plan` | edition ID, architecture, language, destination | immutable expiring plan with exact package/version/runtime, storage calculation, authorization and consent requirements. |
| `jobs.enqueue` | plan ID, plan digest, idempotency key | durable job ID. Repeated key returns same job; changed payload conflicts. Rechecks authorization/capacity. |
| `jobs.pause/resume/cancel/retry` | job ID, expected revision | capability-gated mutations. Cancel acknowledges durable intent and later terminal outcome. Retry cannot bypass verification/authorization. |
| `jobs.snapshot` / `events.replay` | session ID, after sequence | durable snapshot with watermark, or ordered replay; retention miss requires snapshot. |
| `installed.snapshot` | managed registry scope | stable installation IDs with package, paths, version, paired runtime, save policy and health. |
| `installed.inspect` | one explicitly selected absolute local directory | Live but partial external-marker observation only: fixed 196 non-key metadata bytes, unknown retail identity/entitlement/compatibility, unregistered and not launchable. No scan, adoption or file writes. |
| `library.recent` | `limit` 1-100 | Separate TitleHub recently-played window: live/partial, no cursor or Store mapping; never ProductEvidence, ownership, installation or compatibility. Explicit bounded read only. |
| `game.launch` | installation ID, expected revision | supervised launch job, explicit access/runtime/file validation and eventual process outcome. |
| `game.update/rollback/remove` | installation ID + pinned plan/revision; consent | failure-safe jobs; default preserve saves; deletion limited to validated manifest-owned content. |
| `diagnostics.export` | bounded scope, redaction policy | previewable sanitized report, never raw tokens, signed URLs or account identity. |

## Typed result shape

Example data uses invented placeholders, not real product identifiers or working URLs:

```json
{
  "productID":"fixture-harbor",
  "editionID":"fixture-harbor-standard",
  "entitlement":{"kind":"purchase","source":"fixture","checkedAt":"2026-10-03T12:00:00Z","expiresAt":null},
  "installability":{"kind":"downloadable","packageID":"fixture-harbor-arm64","packageVersion":"1.0","reason":null},
  "compatibility":{"kind":"experimental","source":"fixture","checkedAt":"2026-10-03T12:00:00Z","os":"fixture-os","architecture":"arm64","runtimeFingerprint":"fixture-runtime"},
  "installation":{"kind":"notInstalled","installationID":null},
  "inventory":{"completeness":"partial","checkedAt":"2026-10-03T12:00:00Z","lastCompleteAt":null,"reason":"upstream page unavailable"}
}
```

Purchase, subscription, none, unknown never collapse. Subscription has optional expiry with an explicit unknown-expiry policy. Installability distinguishes downloadable, blocked and unknown; compatibility distinguishes verified, experimental, unsupported and unknown. A verified result is scoped to its OS/runtime fingerprint and expires/re-evaluates after changes. Local installation is independent.

Plans define integer `downloadBytes`, `expandedBytes`, `stagingBytes`, `rollbackBytes`, `runtimeBytes`, `reserveBytes`, `reclaimableManagedBytes`, `requiredFreeBytes`, `availableBytes`, exact destination volume, `expiresAt`, `planDigest`, authorization freshness and reasoned warnings. Formula accounts for already verified/reusable files without claiming block-level deltas. Negative/overflow sizes or mismatched digest are errors. Recheck at enqueue and allocation boundaries.

## Jobs, replay and cancellation

```json
{"kind":"event","protocol":{"major":1,"minor":0},"sessionID":"session-001","sequence":43,"requestID":"req-install","jobID":"job-001","revision":4,"event":"job.changed","data":{"state":"verifying","completedBytes":2048,"totalBytes":2048}}
```

Sequence is monotonically increasing within session; revision is monotonic per job. Persist terminal states and watermark transactionally. Duplicate events are ignored; gaps trigger replay; old session IDs trigger snapshot. A snapshot is an authoritative set at watermark, not a list to append. On retention expiry return `EVENTS_EXPIRED` and latest watermark. Apply snapshot first, then events strictly above its watermark. Never use bytes as an identity.

Allowed progression: queued -> downloading -> verifying -> extracting -> committing -> completed. Pause/resume only during supported phases; failure -> recoverable/permanent; cancellation -> cancelling -> cancelled (or completion won the commit race with explicit response). Cancellation request must be idempotent and must not erase an already committed installation. Retries preserve job identity/revision or explicitly link a replacement; no late progress revives terminal jobs.

## Explicit failures

```json
{"kind":"result","protocol":{"major":1,"minor":0},"requestID":"req-002","ok":false,"error":{"code":"INSUFFICIENT_SPACE","message":"More free space is required on the selected volume.","retryable":true,"details":{"requiredBytes":8192,"availableBytes":4096}}}
```

Required codes include `PROTOCOL_MISMATCH`, `CAPABILITY_MISSING`, `AUTH_CANCELLED`, `AUTH_EXPIRED`, `AUTH_INVALID`, `INVENTORY_PARTIAL`, `ACCESS_UNKNOWN`, `ACCESS_REVOKED`, `PACKAGE_AMBIGUOUS`, `PACKAGE_UNAVAILABLE`, `PLAN_EXPIRED`, `PLAN_CHANGED`, `INSUFFICIENT_SPACE`, `NETWORK_UNAVAILABLE`, `INTEGRITY_FAILED`, `RUNTIME_MISMATCH`, `UNSUPPORTED_CONFIGURATION`, `REVISION_CONFLICT`, `EVENTS_EXPIRED`, `CANCELLED`, `REGISTRY_RECOVERY_REQUIRED`, `LAUNCH_FAILED`, `INTERNAL_ERROR`. Diagnostic details are structured/redacted, never raw upstream responses.

Every request ID has exactly one terminal result; jobs continue through events. A transport EOF before terminal result is failure even with exit 0. Nonzero exit overrides apparent success until reconciled. Success must include the correct required result shape and durable state. Test interactive-output contamination, malformed/truncated frames, empty token proof, missing job completion, duplicate sequences, snapshot races and success-after-inner-error.

### Optional native-consent failure diagnostics (source agreement)

The reviewed original ten-pair delta is deployed in the `360e8bf` / `e60481fc`
diagnostic pair, not retroactively applied to the first 57d attempt.
The subsequent fourteen-pair refinement was reviewed and deployed in the
`da0adc0` / `bace09c` pair. After its observed coarse `tokenStructureInvalid`
failure, the coordinator and sole consumer explicitly agreed four further static
subsites with the producer before implementation. That eighteen-pair delta was
reviewed and deployed in the `5ae30fd` / `2acb452` pair. Its actual retry returned
coarse `tokenCipherInvalid`, not a successful authentication window.
The coordinator and sole app then explicitly agreed only three additional
cipher subsites before producer implementation. The twenty-one-pair delta was
reviewed and deployed with consumer `e5a573a` / producer `baf92bc`; its observed
failure was `devicePreparation/tokenCipherEncodingInvalid`. The subsequent
reviewed producer `e7e61fa` removes an unsupported local base64-decoding
predicate on the opaque issuer ticket, retaining strict separate proof-key and
SOAP cryptography. Consumer diagnostics remain compatible and unchanged;
the historical encoding reason is not emitted merely to decode that ticket.
See [paired deployment evidence](VERIFICATION.md). C95/protocol 1.0 stay byte-identical: the existing
optional `flow.error.details` object carries exactly three string keys,
`category`, `stage`, `reason`. Category must be `nativeConsentFailure`; the
consumer accepts only `AUTH_INVALID` with one of these exact closed pairs:

| Stage | Reason |
| --- | --- |
| `privateBootstrap` | `bootstrapInvalid` |
| `clientInitialization` | `clientUnavailable` |
| `devicePreparation` | `credentialStorageUnavailable` |
| `devicePreparation` | `storedCredentialInvalid` |
| `devicePreparation` | `providerRequestFailed` |
| `devicePreparation` | `providerProofInvalid` |
| `devicePreparation` | `registrationProofInvalid` |
| `devicePreparation` | `tokenResponseInvalid` |
| `devicePreparation` | `tokenProofInvalid` |
| `devicePreparation` | `tokenStructureInvalid` |
| `devicePreparation` | `tokenKindInvalid` |
| `devicePreparation` | `tokenAudienceInvalid` |
| `devicePreparation` | `tokenCipherInvalid` |
| `devicePreparation` | `tokenSecretInvalid` |
| `devicePreparation` | `tokenXmlBoundInvalid` |
| `devicePreparation` | `tokenXmlParseInvalid` |
| `devicePreparation` | `tokenCipherEncodingInvalid` |
| `deviceProof` | `proofUnavailable` |
| `nativeSignIn` | `pipelineFailed` |
| `storeProof` | `proofInvalid` |
| `stageUnavailable` | `workerOutcomeUnavailable` |

Missing/unknown/mismatched/extra-key diagnostic objects are not stage evidence.
Their unrecognized data is discarded; local UI says `stageUnavailable`.
Existing strict envelope/schema rules are not relaxed. `AUTH_CANCELLED` and
`AUTH_EXPIRED` retain their existing semantics and never borrow this diagnostic.
Parent/profile/proof/commit errors lacking details keep an unavailable stage,
not a guessed worker stage. No raw upstream message, exception, HTTP/XML,
provider page or credential value is rendered or exported.

`nativeSignIn/pipelineFailed` intentionally covers native UI **or** token exchange;
it does not prove a browser appeared or consent completed. UI maps known pairs
to locally authored descriptions and human-controlled guidance, never automatic
retry, deletion, logout or consent. The producer must preserve a validated
failure handoff when the worker later exits nonzero, but must not accept a success
handoff from an observed failed exit. Missing/invalid/crashed outcomes use honest
unavailable-stage diagnostics. Source review and a new approved artifact/pairing
must precede deployment or another human attempt; this agreement does not
retrospectively diagnose the earlier failed flow.

`devicePreparation/providerProofInvalid` is the legacy coarse invalid-proof
classification, **not necessarily a cryptographic failure**. The refinement
distinguishes failed/missing registration proof, an unsupported/non-single
device response, rejected checked token proof and unsupported proof structure.
It carries no HTTP/XML, identity, audience, token, key or decoded-body values.
Invalid device setup visibly says Microsoft sign-in could not start, without
promoting a guessed deeper cause or recommending credential deletion.

The four additive subsites preserve the older coarse `tokenStructureInvalid`:
`tokenKindInvalid` identifies a converted token that is not Legacy;
`tokenAudienceInvalid` identifies an outer/parsed STS-key mismatch;
`tokenCipherInvalid` identifies a serialized-XML bound/parse failure or
missing/invalid encoded cipher; `tokenSecretInvalid` identifies a missing,
bad-base64 or invalid required 4096-byte/version-4 secret. These descriptions
define static source sites, not values observed from the live attempt.
The consumer presents only format-not-accepted, context-not-matched,
payload-not-processable or proof-missing/invalid wording. It never reports
lengths, versions, keys, XML/HTTP, identity or a presumed cryptographic/provider
rejection. No validation is weakened and no new provider request is authorized.
Whether live data contains XML Schema base64 whitespace remains unproven;
isolated producer fixtures or a parser correction cannot establish that cause.

The three later subsites retain all eighteen older pairs, including coarse
`tokenCipherInvalid`. `tokenXmlBoundInvalid` identifies the existing 64-KiB
serialized-credential guard; `tokenXmlParseInvalid` identifies a failed standalone
EncryptedData reparse; `tokenCipherEncodingInvalid` identifies checked
XML-base64 decoding failure. These are static source definitions, not live
payload evidence. Local copy says only processing limit exceeded, required
format unreadable or encoding unprocessable, without a numeric limit, length,
offset, bytes, XML/parser text, keys or exceptions. Empty cipher and expiry-syntax
guards retain their existing coarse reason. No crypto, nonce, base64 policy,
bound, proof, expiry, scope or lifecycle check changes. The agreement authorizes
diagnostic refinement only, not acceptance of opaque/base64url/unpadded data,
new provider requests or a claim of server rejection, user fault or a live cause.

## Durable registry and updates

Registry schema has its own major/minor version and migration backups. Installation ID is stable; active and rollback versions store package digest, exact runtime pairing, managed manifests and separate save root. Journal records prepare/verify/commit phases; only verified atomic promotion changes active version. Fault-inject at each write/fsync/rename and reconcile on restart. Preserve previous active entry until the new one commits. Cleanup validates every path and refuses traversal, external symlinks or unexpected ownership.

Signed/versioned runtime manifests are independent of package authorization. Invalid signature/hash/version/capability is a hard stop. Unknown consumer API authorization, license or signing model blocks shipping this contract as a live service.
