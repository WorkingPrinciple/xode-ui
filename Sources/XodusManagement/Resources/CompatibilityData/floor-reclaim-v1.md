# Disk-floor reclaim proposal

Read-only sample 2026-10-22T05:57:33.406498+00:00; free **153.991 GiB**. No further deletion authorized.

| Exact path | Allocated MB / GiB | Owner | Disposition / safety basis |
|---|---|---|---|
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/0fd3291c-b0a1-44bd-a536-c80a2405893c/progress.jsonl` | 248.32 / 0.231 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/1e0c7e13-55ed-41a3-9537-6cf5e6a7b83a/progress.jsonl` | 371.08 / 0.346 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/3a4f828b-37c0-4b81-80a7-a508cff2fae2/progress.jsonl` | 160.70 / 0.150 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/4c251e73-d1c2-4dfb-adb0-ccf1f952c327/progress.jsonl` | 174.97 / 0.163 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/6f32dbe6-ff82-444f-abd8-ed9b7995be1b/progress.jsonl` | 927.23 / 0.864 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/93d2b7db-8ca8-470c-b9bb-f690c212d372/progress.jsonl` | 237.95 / 0.222 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/9bfec523-0c29-4da1-8af1-e7b867130ea3/progress.jsonl` | 132.71 / 0.124 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/bbbf3af0-80b8-491d-85fb-511cd0390024/progress.jsonl` | 103.76 / 0.097 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/Library/Application Support/XodusCLI/runs/c38a4145-8d48-4211-b8b2-98df888e3d40/progress.jsonl` | 237.29 / 0.221 | S2 | HOLD: S2 owner explicitly holds all runs/proofs. Temporary mounted HFS staging was already ejected. Do not discard retained progress evidence. |
| `/Users/dragoshont/src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/out` | 0.00 / 0.000 | S5 / dragoshont | HOLD: S5 direct report: root .build/out only, no active build/open files; not release candidate or live app input. Rebuild via swift build/tools/check.sh. Owner/coordinator deletion approval still required. All nested source/.build/out under local-candidates/retained release evidence remain protected. If absent at sample, no remaining reclaim credited. |

No owner-cleared >100MB abandoned prefix established. S2 holds pass/comparison/pending prefixes; LIMBO failed prefix already removed and yields zero new reclaim. Age or absence from frozen packets alone is not safety.

No owner-cleared byte-identical redundant evidence copy established. Proofs/retained release evidence remain held.

Three frozen passive packet files plus owner-verdict metadata; not exhaustive runtime reference proof. Recheck processes immediately before any separately approved deletion.

Proposal only, no deletion authorization. Allocated bytes are not guaranteed physical APFS reclaim. Never delete parent runs, .build root, release candidates, proofs, saves, payloads or linked targets.

Retain every run result.json/events/stdout/stderr receipt. The large run children above are progress evidence, not payload staging. JSON retains completion dates and result receipt hashes. S5 explicitly identified only its root .build/out as a rebuildable candidate; no deletion authorized for it.

## Completed separate authorization

Coordinator explicitly authorized only S4's unused `.build/out`. Removed 117.93 MB allocated after exact-path/non-symlink and empty lsof checks; absence verified. All logs/evidence retained. Cleanup receipt: `floor-reclaim-s4-cleanup-v1.json`. S5 output was already absent when sampled; no additional S5 reclaim credited.
