# Milestones and release gates

All live milestones are proposed. Foundation completion does not imply production readiness.

| Stage | Exit evidence | Stop conditions |
| --- | --- | --- |
| F0 Public foundation | Product/design/requirements/flows/contract/evidence, original editable SVGs, honest native fixture preview, Mac build/tests, committed public draft PR | Real data, private code, fake live controls or unverified build |
| F1 Authorized access proof | Approved auth audience/consent; Keychain proof; cancelled/expired invalid flows; complete PC inventory including never-played purchases and expired subscriptions; provenance and account isolation | History-only inventory, unapproved API/terms, missing paging or ambiguous PC coverage |
| F2 Management adapter | Negotiated structured protocol, explicit errors, durable queue/registry, signed pairing; malformed/EOF/false-success tests | Trusting exit 0, interactive prompts, runtime IPC reused as management without design |
| F3 Safe installation | Edition/package mapping, disk plan math, verification/staging/atomic commit, restart/cancel/network/disk/hash fault injection, safe removal | Save deletion by default, partial installs marked runnable, unsafe paths or irreversible updates |
| F4 Controlled gameplay | Small consented compatibility matrix by OS/hardware/runtime, experimental/unsupported policy, exact paired runtime, supervised launch outcomes | Historical reports relabelled verified, all-title claim, unsupported runtime substitution |
| F5 Consumer beta | GPL-3.0-only compliance and third-party redistribution review; signed/notarized `.app`; approved distribution/updater; privacy review, keyboard/VoiceOver/light-dark/reduce-preferences/resize/localization/offline gates; recoverable telemetry consent design if needed | Any D-03 through D-08 release blocker open, inaccessible core flow or unverifiable runtime integrity |

## Foundation demonstration vs implementation

Foundation covers simulated connection, Library/Discover search, four facets, install planning, space/experimental gates, queue transitions, blocked/error and scenario settings. Job state is in-memory; credentials, network, installed registry and backend process do not exist. Accessibility and localization have explicit release criteria, not an assertion of completed QA.

## Proposed beta success measures

After minimum hardware and authorized title corpus are agreed: 100% of fixture entitlement/package edge cases correctly labelled; zero installs without fresh authority; zero save loss in every injected interruption; 100% terminal jobs consistent with registry; the [response-time targets](REQUIREMENTS.md) measured rather than assumed. Track first successful authorized install and launch, error recovery and cancellation completion, not downloads or catalog size as a proxy.
