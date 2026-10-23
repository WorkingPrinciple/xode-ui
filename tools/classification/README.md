# Descriptive metadata candidate

`game-compatibility-v1.json` remains the canonical authoring database. Its
`desktopCatalog` fields and `desktopCatalogSnapshot` are additive catalogue
observations, **not changes to the legacy action policy**. The new
`PublicMetadata/game-metadata-v1.json` projection has its own schema
`urn:xodus:game-metadata:1` and no `supported01`, launch evidence, QA records,
account responses or local file paths.

## Capture and validation

From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/classification/game_metadata.py --capture
PYTHONDONTWRITEBYTECODE=1 python3 tools/classification/game_metadata.py --export
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/classification -p 'test_game_metadata.py'
PYTHONDONTWRITEBYTECODE=1 python3 tools/classification/classify_catalogue.py
```

Capture reads only the public RO `All PC Games` feed and public Display Catalog,
at most 600 product IDs in 30 batches plus one feed request, three HTTP attempts
per request with bounded backoff, 16 MiB per response and 64 MiB per snapshot.
The elapsed-time budget is checked before each new request. No account queries,
game downloads, installation, scanner runs or execution are involved. Fatal
fetch/budget/schema errors leave the prior database on disk; missing product
responses are recorded as partial. Raw upstream responses are hashed but never
persisted or exported.

Capture preserves existing anti-cheat, package classification, technical history
and action-policy fields exactly. The older `classify_catalogue.py --refresh`
also refreshes anti-cheat/legacy classifications and is a separate operation:
do not use it for a metadata-only update. Its package collector now only accepts
packages explicitly declaring `Windows.Desktop`, preserving raw format plus
SKU/content/package/version/architecture identity. Unknown formats remain unknown.

Export is offline and deterministic for fixed database, source files, notices
and source commit. It validates the closed JSON Schema using the dependency-free
validator for exactly the schema keywords in use. The manifest pins the authoring
database, extractor source bytes and source commit; `SHA256SUMS` covers every
candidate file and the manifest. No updater or signing system is introduced.

## Counting and anti-cheat semantics

`count-audit-v1.json` defines the conservative local certification rules and
enumerates each excluded product ID/reason. The count requires current scoped
membership, explicit full non-bundle/non-preorder game metadata, a past market
Store listing date and a known desktop package family. Previews, demos,
launchers, ambiguous editions/collections and duplicate title/group/content/
package-family identity components are excluded. Different SKUs retain their
observations; product IDs are not title-merged. This is a **source-declared
catalogue-rule count**, not worldwide release verification, entitlement,
runtime support, or proof that every edition relationship in the world is known.
One feed ID absent from the authoring database is explicitly excluded rather
than silently created. Old products outside the current scope retain history.

Legacy `none` becomes `not-detected` for filename inventories or `manual-override`
for user-directed classifications, never verified absence. Named claims have
unknown Xbox-PC build binding. PCGamingWiki imported claims are withheld pending
terms review; links alone remain. AWACY-derived names include its MIT notice.
No exported record grants or denies Install/Play.

## Distribution / S5 integration

The files under
`Sources/XodusManagement/Resources/CompatibilityData/PublicMetadata/` are the
only reusable candidate. **Release is held** until source redistribution rights
are approved. Do not publish a release, zip all CompatibilityData, or implement
an updater as part of this MVP. No new dependencies or backend are required.

S5 may later add a descriptive reader for schema/minimum reader version 1
through the existing XodusManagement resource bundle. Verify manifest digest,
byte/record bounds and schema; display unknown/raw families without converting
them to support flags. Keep the existing `game-compatibility-v1.json` reader and
execution policy separate. Bundle the exact admitted projection and notices in
the signed app only after the rights hold is resolved. Current snapshot status
is partial if any current-feed ID lacks a canonical record.

The old `OfflineGameCompatibility.swift` in the S4 checkout still rejects any
legacy anti-cheat other than `unknown`; it already rejects the inherited
enriched database. This change does not claim to repair or validate that old
app policy. S5 must use its admitted newer legacy reader and a separate metadata
adapter; passing metadata tests is not installed-app integration evidence.
