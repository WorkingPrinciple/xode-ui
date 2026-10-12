# Pause handoff

Preserve the functional Xodus + CrossOver MSIXVC/NMS path. UWP, EAppx and new
Wine work are parked. This is source recovery, not release publication.
One read-only SSH pass on 2026-10-12 recovered the identities below; no build,
signing, deployment, restart or later game run was performed.

## App package and installation history

Mac artifact paths below are relative to the owner's home, not public downloads.

| Source | Package directory under `~/xodus-app-tooling/` | Package receipt SHA-256 |
|---|---|---|
| `02e67f89c01dbd9ea3549a1fc628adbfcfbad29a` | `app-launcher-02e67f8-20261010/packages/Xodus-controlled-pair.QLD1Q7` | `0c84fa4f5b25157bfd27d94b09cb9f87674574cde5a58795b3094c4b80ec4133` |
| `fac58d6f501c356a0e763d397263e5a0a30b3477` | `app-launcher-fac58d6-20261010/packages/Xodus-controlled-pair.0FnKEG` | `f1a1f88b71531967d2db1f2dc4e36177d25b74a7412a3d196561897e7ab72798` |

Each directory contains `Xodus.app` and `package-receipt.json`; the receipts
include archived source/file hash inventories. Source trees respectively:
`09b06ebe8432575390f5f37a613c8cb133dc7f3a` and
`818ee7ea618a30026d1de7e8b32766be826e281a`.

Both `app-launcher-<short-source>-20261010/deployment-receipt.json` files exist.
Their SHA-256 values respectively are
`3671c1213931dadef315f3c7d655cfb4d1ceb0617e9b77afb224f1e43dfd79e2`
and `a786ae3d4d0de934b3d293cb74fc8077bb4009d4a7040e15a64314dc0c9a3609`.
Historical evidence records fac58d6 deployed after 02e67f8, not merely staged.
Do not describe 02e67f8 as the current installation. The current bundle at
`~/xodus-app-tooling/app-foundation/dist/Xodus.app` has version 0.2.0/build 2;
its Info.plist SHA-256 is
`5cd72a600a0a2aad1895d4cb5c505aab878aee116772f175d899bf163b85dc38`.
That generic version does not identify its current source commit.
Later foundation/M1/M3/M7/M10 source integration is not installation proof.

## Exact runtime pins

Both recovered package receipts agree:

| Artifact | SHA-256 | Bytes |
|---|---|---|
| Signed bundled management CLI | `c8fe69a3bc2b6a84c5bad5ef0c1ae041f36466a87419c0f17d9567c6df3ed14d` | 22012176 |
| External unsigned management CLI | `d1b314bb7d36e798ca51cb38dd715c14ac928de311f215ed8d67af7e549ae01e` | 22122624 |
| Frozen credential broker | `2c40354c471c7a692cc64eea473a2fe1d34630c140341010ae9967e9742c9381` | 228448 |
| Currently read runtime service | `24e78d536c05c52e0e5e1e8f4373c68c41c079ef68a7891eff307baeb17edfba` | 14401120 |

Service location: `~/Library/Application Support/Xodus/Runtime/bin/xodus-service`.
Broker location: `~/Library/Application Support/Xodus/CredentialBroker/XodusCredentialBroker`.
The service hash is a current read, not proven paired to the historical app
receipts or a backend build commit. `Runtime/bin/xodus-cli` was absent; do not
substitute the management CLI for that nonexistent path. The prior handoff's
`da24ce15...` CLI attribution is superseded by the actual package receipts.

## Backend source and preservation gap

Current Mac source base: `~/src/xodus-macos-private-ai`.
Branch: `private/ai-hogwarts-runtime`.
HEAD: `87ccc73af0811e7bc007a2ad97035d39e8eed96b`.
Tracked-file inventory was recovered privately.
Working-tree changes:

- Modified `scripts/macos/private-xodus-generic-wine.sh`.
- Untracked `LEGACY_XODUS_AI_LINEAGE.txt`.
- Untracked `scripts/macos/private-xodus-generic-wine.sh.d3dmetal-only.bak`.

Dashboard `a3036bf` is a historical local-backend short identity, not this HEAD.
Its full historical SHA and ancestry were not recovered in the bounded pass.
Public API failure does not establish absence from the private/local repository.

**No backend push or snapshot publication was performed.** File inventory alone
cannot establish secret-free contents/history; the dirty and untracked source
also cannot be represented by HEAD alone. Neither selected source contents nor
history was inspected sufficiently to authorize uploading to the private
preservation branch. This is the explicit preservation blocker; do not archive
the whole tooling directory, prefixes, credentials, game files or proprietary
runtime binaries. App source is already in GitHub. Retained source bundles and
package receipts exist, but no verified single portable backend/runtime/app
handoff archive was established.

## No Man's Sky

Registered script:
`~/Library/Application Support/XodusRemote/launchers/BQVQTL3PCH05.sh`.
SHA-256: `83853462a54fd070b516f1980bbeae2ab429486dfe392120092914cdb4e3fd3a`
(494 bytes).
Current delegation:
`~/Library/Application Support/Xodus/Runtime-NMS-BQVQTL3PCH05-76/scripts/macos/private-xodus-launch.sh`.
Game folder: `~/Games/Xodus/NoMansSky-Xbox`; bottle `Xodus-BQVQTL3PCH05`.
Historical repaired 7.6 evidence records in-world rendering; this read does not
revalidate gameplay or bind the current script bytes to that historical run.
No later game run occurred in this recovery pass.

## Remaining evidence boundaries

Current app executable/source identity, full historical a3036bf identity,
backend build-to-service mapping, dirty-source preservation, paired-inputs
existence and game-success-bound script digest remain unestablished.
Raw receipts, logs, account data and tracked-file inventory stay private.
For github.com coordinator/API reads, remove inherited `GH_TOKEN` and set
`GH_HOST=github.com`; never print credentials or change global authentication.
