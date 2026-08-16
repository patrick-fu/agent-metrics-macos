# SQLite retention candidates

THROW AWAY decision aid for [Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10).

These three strategies are mutually exclusive. Measured Node/`node:sqlite` ranges in `results/benchmark-results.md` are one Apple silicon developer Mac. They are not AppKit, Swift, fleet, or release-contract facts. 20k facts remains the hot/query working set from issue 7; it is not a retention policy.

Local repeats: 10k and 100k five full runs; 1m five load/query runs and three mutation runs.

| Scale | bytes/fact | All raw query | 7d raw query | VACUUM | backup |
| --- | --- | --- | --- | --- | --- |
| 10k | 499.3–500.1 B | 19–27 ms | 7–11 ms | 4.9–5.5 ms | 5.8–6.4 ms |
| 100k | 500.0–500.2 B | 473–507 ms | 178–188 ms | 72–92 ms | 55–70 ms |
| 1m | 501.8–501.9 B | 6083–6473 ms | 2261–2450 ms | 720–790 ms | 549–588 ms |

Index bytes stay about 37% of the file. Exact Decode TPS p50/p95 scanned 6909–7085 raw samples at 10k, 69604–70083 at 100k, and 697359–698136 at 1m. Query cost tracks retained raw samples, not the 20k working set.

Workload caveat: timestamps are recency-biased, not a uniform 400-day history. About 38% of contributing facts land in 7d. A uniform 400-day history would put about 1.75% in 7d and 22.5% in 90d. B/C space savings below are therefore a lower bound for a mature steady user.

After compaction on the 1m snapshot:

- A raw: 502 MB, 1_000_000 raw facts, All-history exact Decode TPS available
- B 90d raw + daily rollup: 370 MB, 655_798 remaining raw facts; All-history exact Decode TPS unavailable; 90d exact still available
- C 7d raw + totals: 265 MB, 382_729 remaining raw facts; exact Decode TPS only inside 7d

At 10k, B and C can be slightly larger than A because daily rollup cardinality does not yet collapse. The size win appears at 100k (50 MB → 37 MB → 26 MB) and 1m.

Query path vs retention: the 1m All raw scan (6.1–6.5 s) and even the 7d raw scan (2.26–2.45 s) are too slow for a UI thread. That is already decided by issue 7: live detail must use a 20k hot/query working set or a pre-aggregated path. Those timings are not a reason to delete history. They are a reason to keep historical queries off the UI thread.

## A. Unlimited raw, optional capacity ceiling

Keep every contributing Usage Fact until a byte or row ceiling. All windows can recompute exact Decode TPS. Disappeared source logs still leave history intact.

Tradeoff: file growth is linear at ~500 B/fact. 1m is already 502 MB on this machine. Backup and VACUUM stay sub-second at 1m; source-scoped rebuild is 3.0–3.1 s and 90-day delete is 4.1–4.6 s. Choose A if All-history exact quantiles must remain possible.

## B. 90-day raw + long-term rollup — recommended

Keep raw facts for 90 days. Older contributing facts become daily rollups of mutually exclusive token parts, call counts, and fact counts. Exact Decode TPS stays available inside the 90-day raw window and is **unavailable** for All-history. All / 1y Token Burn and Output Throughput stay answerable only as rollup totals, not as exact quantiles.

Why recommend B as the P0 default:

- The accepted P0 performance windows are 15m / 1h / 24h / 7d. 90 days keeps a buffer beyond that window and beyond Claude Code's default 30-day source-log lifetime.
- On this recency-biased 1m snapshot, B already saves 132 MB versus A. A uniform long history would save more.
- C saves only another 105 MB here, but drops exact Decode TPS for every window longer than 7d.

Tradeoff: All-history exact quantile is gone. Remaining-raw All after B still has hundreds of thousands of samples on this workload, so the UI must keep using the 20k working set. A 2k-fact compact check conserved contributing fact counts and output totals (1821 = 1238 raw + 583 daily rollups). Rollups still cannot reconstruct exact p50/p95. Daily `COUNT(DISTINCT model_call_id)` is not a global call identity.

## C. 7-day raw, earlier totals only

Keep raw facts only for the P0 7-day performance window. Older data is daily totals. Smallest file (265 MB at 1m). Exact quantile exists only inside 7 days.

Tradeoff: 90d / 1y / All exact Decode TPS are gone. That is a bigger product cut than the extra 105 MB saved versus B on this recency-biased 1m snapshot.

## Source logs that later disappear

Default keep. On this machine the harness marked `src-claude` `log_present=0` and retained 4789 / 47865 / 479789 facts at the three scales. Disappeared logs make live Coverage partial and Data State stale; they are not a delete signal. Reset Data is the only user-facing wipe.

## P0 choices for Patrick

Do not treat these as closed.

1. Default retention: A, **B (recommended)**, or C.
2. User-visible control in P0: no setting (**recommended**), or expose A/B/C.
3. Capacity warning / ceiling, even on B:
   - warn at 750 MiB or 1.5 million facts
   - hard ceiling at 1 GiB or 2 million facts
   - at the ceiling, stop accepting new facts until eviction finishes; do not silently write past the cap
4. Delete order: superseded then oldest contributing (**recommended**); oldest first; or source-scoped only. Disappeared logs are not in this queue.
5. Can a rollup recompute exact Decode TPS? **No**, unless the raw samples are still stored.
6. Reset Data: delete Usage Facts, rollups, and cursors; keep schema; do not touch source logs. That is distinct from log disappearance.
7. Backup / VACUUM:
   - `VACUUM INTO` before any schema change (549–588 ms at 1m)
   - `incremental_vacuum` after every compact (97–114 ms at 1m) — it is not a substitute for reclaiming space
   - full `VACUUM` after a compact or delete that leaves more than about 10% bloat (720–790 ms at 1m; 90d delete then incremental_vacuum left 468 MB / 712 B/fact, and VACUUM brought it back to 330 MB / 502 B/fact)

## Suggested acceptance statement

If B is accepted:

> Accept candidate B as the P0 SQLite retention default: keep raw Usage Facts for 90 days, roll older contributing facts into daily mutually exclusive token totals, and treat exact Decode TPS as available only while raw samples remain. Keep the 20k fact budget as the hot/query working set, not as retention. Do not delete canonical facts when a source log later disappears; mark `log_present=0` and degrade live Coverage / Data State instead. Warn at 750 MiB or 1.5 million facts and enforce a 1 GiB or 2 million fact ceiling by evicting superseded facts before oldest contributing facts. Reset Data wipes facts, rollups, and cursors only. Backup with `VACUUM INTO` before schema changes, run `incremental_vacuum` after compact, and run a full `VACUUM` after large deletes. Treat the Node timings as local evidence, not a fleet SLO.
