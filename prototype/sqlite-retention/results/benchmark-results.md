# SQLite retention local results

THROW AWAY. Synthetic fixtures only.

Measured numbers are from one Apple silicon developer Mac and a Node `node:sqlite` process. They are not AppKit, Swift, fleet, or release-contract facts. Do not treat a single-machine range as an SLO.

20k facts is the accepted hot/query working set from issue 7. It is not SQLite persistent retention.

SQLite used: 3.51.2 via node:sqlite. Node 25.6.1.

Result key: `PASS`/`FAIL` = correctness assertion. `MEASURED` = ungated local timing or size.

| Check | Kind | Measured | Suggested / expected | Result |
| --- | --- | --- | --- | --- |
| cumulative watermark uses positive delta only | assertion | {"delta":40,"rebuild":false,"watermark":140} | {"delta":40,"rebuild":false} | PASS |
| counter rollback triggers source-scoped rebuild, not a negative delta | assertion | {"delta":0,"rebuild":true,"watermark":140} | {"delta":0,"rebuild":true} | PASS |
| decode TPS v1 formula | assertion | 60 | (output_total-1)/(duration-TTFT)=60 | PASS |
| decode TPS unavailable when n<2 | assertion | n/a | unavailable | PASS |
| hot/query working set is 20k facts, not retention | assertion | 20000 | 20000 | PASS |
| tiny Codex cache_write NULL | assertion | 0 | 0 | PASS |
| tiny Claude output_visible NULL | assertion | 0 | 0 | PASS |
| tiny Claude reasoning NULL | assertion | 0 | 0 | PASS |
| tiny unavailable not stored as 0 | assertion | 0 | 0 | PASS |
| multi-select derives after summing raw samples | assertion | 0.3023 | sum raw output tokens, then divide by window | PASS |
| 10000 facts exceed the 20k hot/query working set or stay distinct from retention | assertion | {"facts":10000,"hotQueryWorkingSet":20000} | 20k is working set, not a retention policy | PASS |
| 10000 Codex cache_write stays NULL | assertion | all NULL | Codex cache_write NULL (overlap unverified) | PASS |
| 10000 Claude output_visible/reasoning stay NULL | assertion | all NULL | Claude visible/reasoning NULL | PASS |
| 10000 unavailable is not stored as 0 | assertion | no zero-for-unavailable | NULL means unavailable | PASS |
| 10000 disappeared source logs do not delete canonical facts by default | assertion | {"kept":4789,"before":4789} | keep facts; log_present=0 | PASS |
| 10000 bytes/fact | measurement | {"min":499.3024,"max":500.1216,"n":5,"values":[499.712,499.3024,500.1216,499.3024,499.712]} | local range only | MEASURED |
| 10000 All query ms | measurement | {"min":19.07154199999991,"max":26.771500000000003,"n":5,"values":[26.771500000000003,19.223915999999974,19.242417000000046,19.07154199999991,19.893707999999833]} | local range only | MEASURED |
| 10000 7d query ms | measurement | {"min":7.156167000000039,"max":10.778583000000026,"n":5,"values":[10.778583000000026,7.156167000000039,7.199999999999932,7.233292000000006,7.459165999999982]} | local range only | MEASURED |
| 10000 VACUUM ms | measurement | {"min":4.942874999999958,"max":5.508249999999975,"n":5,"values":[5.404375000000016,5.096916999999962,4.942874999999958,5.508249999999975,5.454250000000002]} | local range only | MEASURED |
| 10000 backup ms | measurement | {"min":5.842417000000012,"max":6.41233299999999,"n":5,"values":[5.967583000000047,5.842417000000012,5.853457999999932,6.023874999999975,6.41233299999999]} | local range only | MEASURED |
| 10000 All vs 7d exact-quantile raw samples | measurement | {"all":{"min":6909,"max":7085,"n":5,"values":[6917,6909,7085,6932,6959]},"week":{"min":2633,"max":2728,"n":5,"values":[2638,2633,2728,2667,2633]}} | exact quantile needs raw samples; rollups cannot recompute it | MEASURED |
| 100000 facts exceed the 20k hot/query working set or stay distinct from retention | assertion | {"facts":100000,"hotQueryWorkingSet":20000} | 20k is working set, not a retention policy | PASS |
| 100000 Codex cache_write stays NULL | assertion | all NULL | Codex cache_write NULL (overlap unverified) | PASS |
| 100000 Claude output_visible/reasoning stay NULL | assertion | all NULL | Claude visible/reasoning NULL | PASS |
| 100000 unavailable is not stored as 0 | assertion | no zero-for-unavailable | NULL means unavailable | PASS |
| 100000 disappeared source logs do not delete canonical facts by default | assertion | {"kept":47865,"before":47865} | keep facts; log_present=0 | PASS |
| 100000 bytes/fact | measurement | {"min":500.03968,"max":500.20352,"n":5,"values":[500.08064,500.20352,500.16256,500.03968,500.03968]} | local range only | MEASURED |
| 100000 All query ms | measurement | {"min":473.145625000001,"max":506.8523750000004,"n":5,"values":[487.940208,491.27016599999934,506.8523750000004,478.27029200000106,473.145625000001]} | local range only | MEASURED |
| 100000 7d query ms | measurement | {"min":177.96854199999962,"max":187.684874999999,"n":5,"values":[187.2825829999997,177.96854199999962,183.2654590000002,187.684874999999,182.58787499999926]} | local range only | MEASURED |
| 100000 VACUUM ms | measurement | {"min":72.29049999999916,"max":91.87779099999989,"n":5,"values":[91.87779099999989,76.02199999999993,72.29049999999916,74.730375000001,73.04720799999996]} | local range only | MEASURED |
| 100000 backup ms | measurement | {"min":55.26604099999895,"max":69.64300000000003,"n":5,"values":[58.18762499999957,69.64300000000003,57.58391699999993,55.883708999999726,55.26604099999895]} | local range only | MEASURED |
| 100000 All vs 7d exact-quantile raw samples | measurement | {"all":{"min":69604,"max":70083,"n":5,"values":[69927,69797,70083,69838,69604]},"week":{"min":26519,"max":26922,"n":5,"values":[26752,26652,26922,26789,26519]}} | exact quantile needs raw samples; rollups cannot recompute it | MEASURED |
| 1000000 facts exceed the 20k hot/query working set or stay distinct from retention | assertion | {"facts":1000000,"hotQueryWorkingSet":20000} | 20k is working set, not a retention policy | PASS |
| 1000000 Codex cache_write stays NULL | assertion | all NULL | Codex cache_write NULL (overlap unverified) | PASS |
| 1000000 Claude output_visible/reasoning stay NULL | assertion | all NULL | Claude visible/reasoning NULL | PASS |
| 1000000 unavailable is not stored as 0 | assertion | no zero-for-unavailable | NULL means unavailable | PASS |
| 1000000 disappeared source logs do not delete canonical facts by default | assertion | {"kept":479789,"before":479789} | keep facts; log_present=0 | PASS |
| 1000000 bytes/fact | measurement | {"min":501.817344,"max":501.8624,"n":5,"values":[501.846016,501.817344,501.82144,501.82144,501.8624]} | local range only | MEASURED |
| 1000000 All query ms | measurement | {"min":6083.225707999984,"max":6472.564917000011,"n":5,"values":[6236.845290999998,6472.564917000011,6227.351374999998,6088.100584,6083.225707999984]} | local range only | MEASURED |
| 1000000 7d query ms | measurement | {"min":2260.707208000007,"max":2449.7560840000224,"n":5,"values":[2378.0537500000064,2308.0339999999997,2260.707208000007,2383.858833999984,2449.7560840000224]} | local range only | MEASURED |
| 1000000 VACUUM ms | measurement | {"min":719.9620839999989,"max":790.1986660000039,"n":3,"values":[790.1986660000039,726.1428339999984,719.9620839999989]} | local range only | MEASURED |
| 1000000 backup ms | measurement | {"min":548.8711670000048,"max":587.7651659999974,"n":3,"values":[549.9962079999968,548.8711670000048,587.7651659999974]} | local range only | MEASURED |
| 1000000 All vs 7d exact-quantile raw samples | measurement | {"all":{"min":697359,"max":698136,"n":5,"values":[698136,697943,697594,697359,697566]},"week":{"min":267299,"max":268010,"n":5,"values":[267371,267299,268010,267497,267346]}} | exact quantile needs raw samples; rollups cannot recompute it | MEASURED |
| public artifact privacy scan | assertion | [] | [] | PASS |
| 90d compact conserves contributing fact counts via raw+rollup | assertion | 2000-fact tiny: 1821 = 1238 raw + 583 rollup | raw remaining + rollup fact_count | PASS |
| 90d compact conserves output token totals via raw+rollup | assertion | 1205263 = 821403 + 383860 | raw remaining + rollup output_total | PASS |
| compacted All-history exact quantile is unavailable | assertion | remaining-raw samples 945 < pre-compact contributing facts | remaining-raw is not All-history | PASS |

## Scale ranges

### 10000 facts

- runs completed: 5
- bytes/fact: 499.3024–500.1216 (n=5)
- DB bytes: 4993024–5001216 (n=5)
- index bytes: 1867776–1871872 (n=5)
- WAL bytes before checkpoint (load): 4231272–4235392 (n=5)
- All query ms: 19.0715–26.7715 (n=5)
- 7d query ms: 7.1562–10.7786 (n=5)
- All exact-quantile samples: 6909–7085 (n=5)
- 7d exact-quantile samples: 2633–2728 (n=5)
- VACUUM ms: 4.9429–5.5082 (n=5)
- backup ms: 5.8424–6.4123 (n=5)
- source-scoped rebuild ms: 15.0405–17.0956 (n=5)
- source log disappear default: kept 4789 of 4789 facts
- strategy snapshots:
  - A-raw-or-capacity: db=4997120 bytes/fact=499.7, All-history exact quantile=true, 7d exact quantile=true
  - B-90d-raw-plus-rollup: db=5406720 bytes/fact=821.9, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true
  - C-7d-raw-plus-totals: db=5730304 bytes/fact=1496.6, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true

### 100000 facts

- runs completed: 5
- bytes/fact: 500.0397–500.2035 (n=5)
- DB bytes: 50003968–50020352 (n=5)
- index bytes: 18706432–18710528 (n=5)
- WAL bytes before checkpoint (load): 11544272–11548392 (n=5)
- All query ms: 473.1456–506.8524 (n=5)
- 7d query ms: 177.9685–187.6849 (n=5)
- All exact-quantile samples: 69604–70083 (n=5)
- 7d exact-quantile samples: 26519–26922 (n=5)
- VACUUM ms: 72.2905–91.8778 (n=5)
- backup ms: 55.2660–69.6430 (n=5)
- source-scoped rebuild ms: 227.8041–243.2091 (n=5)
- source log disappear default: kept 47865 of 47865 facts
- strategy snapshots:
  - A-raw-or-capacity: db=50008064 bytes/fact=500.1, All-history exact quantile=true, 7d exact quantile=true
  - B-90d-raw-plus-rollup: db=36790272 bytes/fact=561.8, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true
  - C-7d-raw-plus-totals: db=26341376 bytes/fact=690.1, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true

### 1000000 facts

- runs completed: 5
- bytes/fact: 501.8173–501.8624 (n=5)
- DB bytes: 501817344–501862400 (n=5)
- index bytes: 188567552–188575744 (n=5)
- WAL bytes before checkpoint (load): 77179992
- All query ms: 6083.2257–6472.5649 (n=5)
- 7d query ms: 2260.7072–2449.7561 (n=5)
- All exact-quantile samples: 697359–698136 (n=5)
- 7d exact-quantile samples: 267299–268010 (n=5)
- VACUUM ms: 719.9621–790.1987 (n=3)
- backup ms: 548.8712–587.7652 (n=3)
- source-scoped rebuild ms: 2994.0488–3060.0743 (n=3)
- source log disappear default: kept 479789 of 479789 facts
- strategy snapshots:
  - A-raw-or-capacity: db=501846016 bytes/fact=501.8, All-history exact quantile=true, 7d exact quantile=true
  - B-90d-raw-plus-rollup: db=369561600 bytes/fact=563.5, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true
  - C-7d-raw-plus-totals: db=264617984 bytes/fact=691.4, All-history exact quantile=false, remaining-raw samples exist, 7d exact quantile=true

## Unverified assumptions

- Real JSONL tail rates and AppKit/SQLite writer interleaving on a developer Mac.
- Production page cache, backup destination, and user-visible Reset Data confirmation copy.
- Whether a later release should expose retention as a setting; this prototype only measures options.
- Workload timestamps are recency-biased (about 38% of facts fall in 7d), not a uniform 400-day history. B/C space savings are a lower bound for a mature steady user.
- Remaining-raw Decode TPS samples after B/C are not All-history samples. All-history exact quantile is available only under A.


## Post-hoc P0 policy assertions

The 10k/100k/1m size and query ranges above were not rerun. Capacity-ladder and expanded Reset Data checks live in `p0-policy-assertions.md`. They are logic assertions added after those measurements.
