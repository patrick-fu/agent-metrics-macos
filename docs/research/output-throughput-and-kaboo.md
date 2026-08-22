# Output Throughput 与 Kaboo 菜单栏指标：源码定向研究

研究日期：2026-08-22。

范围与安全：本文只引用 `coding-agent-metrics` 的产品源码、单元测试和所请求 Kaboo 路径的存在性检查；不含 prompt、业务代码、usage JSONL 正文、用户模型列表或本机绝对路径。`[产品事实]` 是当前 App 已由源码/测试核验的行为；`[Kaboo 事实]` 仅在 Kaboo 源码可取得时才可成立；`[设计建议]` 是建议而非现状。

## 结论

- `[产品事实]` 底部 **Output Throughput** 是所选 observation 在固定、实时滑动的 **180 秒**窗口内的 `outputTokens` 总和除以 **180 秒**，不是每个模型调用的 Decode TPS，也不是平均每个 session 的 TPS。标签 `3m` 正是该固定分母。`Sources/CodingAgentMetricsCore/Domain.swift:224-227`，`Sources/CodingAgentMetricsCore/LiveSampler.swift:10-20`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:131-145`
- `[产品事实]` 多个 session、模型与 agent（通过 filter 后）贡献会相加；同一模型调用的 fallback/enhanced 重叠 observation 会 coalesce，避免双算，而不是被平均。`Sources/CodingAgentMetricsCore/AuthorityCoalescing.swift:13-84`，`Tests/CodingAgentMetricsCoreTests/TrendBuilderTests.swift:337-379`
- `[Kaboo 历史研究记录；当前未复核]` 上一轮已记录 Kaboo 的菜单栏 TPS、TPM、bucket 和聚合语义；本机指定源树当前不存在，未找到可核验替代检出。因此该节明确保留其历史记录性质，不能被解读为本次新鲜源码事实。
- `[设计建议]` Summary 默认显示数值、范围/筛选和一行可信度；将正常态的重复 metadata 收进详情，并把无数据的原因与一个可执行入口合并为一处。

## 1. Output Throughput 的当前实现

### UI、刷新与“3m”

`[产品事实]` Summary 底部块固定显示标题、`3m`、数值和 `tokens/s`；无值显示 `-`。它还将 Quality、State、Coverage、Updated/Retained、样本数、definition、source、scope、reason/action 交给 metadata 行；`View Trends` 按当前 filter 打开详情。`Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift:93-115`，`Sources/CodingAgentMetricsApp/SummaryPopoverView.swift:112-147`

`[产品事实]` `3m = 180 seconds`，定义版本为 `output-throughput-v1`，不是「最近三个完整分钟 bucket」或「自 session 开始三分钟」。实时选择范围为闭区间 `[now - 180s, now]`。`Sources/CodingAgentMetricsCore/Domain.swift:224-227`，`Sources/CodingAgentMetricsCore/LiveSampler.swift:10-20`

`[产品事实]` 状态栏 timer 每 **0.25s**触发一次请求；runtime 对 light snapshot 限流到约 **1s**，对可见 popover 的 detail 限流到约 **0.25s**；隐藏详情时不发布 detail。故底部值通常按约 1 秒更新，打开 Trends 后详情可按约 250ms 重算。`Sources/CodingAgentMetricsApp/StatusItemController.swift:206-216,241-252`，`Sources/CodingAgentMetricsCore/BoundedRuntime.swift:153-185`

### 公式、过滤与并发

`[产品事实]` Light KPI 的完整定义：

```text
W = [now - 180s, now]
F = AuthorityCoalescing.select(all facts satisfying Agent AND Model filter)
N = Σ fact.outputTokens, for facts in F whose observedAt ∈ W
Output Throughput = N / 180 seconds     (tokens/s)
```

没有任何除以 session 数、model 数或样本数的步骤。`MetricFilter` 两个非空轴是 AND；空集合表示 All。故同时跑 10 个 session/model 时，保留的十者都落在 filter 内就求和；过滤到一个 agent/model 就只算交集。`Sources/CodingAgentMetricsCore/MetricFilter.swift:3-45`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:83-150`，`Tests/CodingAgentMetricsCoreTests/FilteredLightSnapshotTests.swift:11-20,124-137`

`[产品事实]` Authority coalescing 的单位是 durable `modelCallID`（缺失时是 fact ID）：enhanced authority 替代同一 cohort 的 fallback；同级 authority 冲突则排除 cohort 并标 partial。这是防重，不是平均。`Sources/CodingAgentMetricsCore/AuthorityCoalescing.swift:13-84`

### bucket、变化快与趋势图

`[产品事实]` 大 KPI 不按 bucket 除法，而是固定除以 180；趋势才把同一个 180 秒范围切为 **5 秒** bucket。`closedEnd = floor(now / 5s) × 5s`，完整 bucket 是 `[start, closedEnd)`，当前未闭合 bucket 仅占位且没有 value/count；完整 bucket 的值是 `bucket outputTokens / 5s`。`Sources/CodingAgentMetricsCore/TrendBuilder.swift:65-105,213-225,325-327`，`Tests/CodingAgentMetricsCoreTests/TrendBuilderTests.swift:10-66`

`[产品事实]` 因而数值看起来变化快有三类正常原因：(1) 约 1 秒重取快照；(2) 新 observation 进入或旧 observation 越过滑动左边界会立刻改变分子，但分母恒为 180；(3) 打开详情时每 5 秒闭合一个趋势 bucket。它不是「每 1 秒平均 TPS」；更不是每个调用的 streaming decode 速率。

### stale、retained、partial、quality

`[产品事实]` 正常输出 facts 的 quality 合并后通常为 `Derived`；`Measured/Derived/Estimated/Unavailable` 描述获得方式，不能推断新鲜度。`State` 独立表示 `Zero`（可用值为 0）、`Stale`（回填最后好数据）、`No data`（无 observation）、`Unavailable`（无法形成值）；正常态不显示 state。`Coverage=Partial` 可由退化源、混合质量、不可用/不支持 fact、authority conflict 等触发。`Sources/CodingAgentMetricsCore/Domain.swift:3-25`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:92-150`，`Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift:222-241`

`[产品事实]` 一旦源不健康，light snapshot 可在窗口内回填该源的 last-good facts；有 retained 数据的值会标 `Stale`，freshness 文案追加 `Retained`，coverage 往往为 `Partial`。这不是数据库「保留期」或重新测得的新值。`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:347-382`，`Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift:53-58`，`Tests/CodingAgentMetricsCoreTests/DegradedDataContractTests.swift:86-130`

`[产品事实]` 因此，当界面同时显示 `Stale · Retained · Partial` 时，大号数字不能解读为「此刻最近 3 分钟」。实现会以该源最新一条可用 fact 为右端点，向前取 180 秒的历史窗口，再把其 output 总量除以 180；bounded ingestion 继续追赶或 last-good cohort 改变时，这个旧值仍可能按约 1 秒刷新并产生跳变。`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:92-150,347-382`

## 2. Summary 项目、状态、metadata 与无数据

| 项目 | `[产品事实]` 当前含义/公式 | 主要无数据原因 |
|---|---|---|
| Token Burn/min | 最近 600s 的可用 `normalizedBurnTotal` 之和 ÷ 600 × 60；互斥部分是 input uncached、cache read、cache write、output visible、reasoning。 | token parts 无法互斥归一或源不支持，`UNSUPPORTED_CAPABILITY`；部分缺失会 `Partial`。`Sources/CodingAgentMetricsCore/UsageModels.swift:3-33,172-234`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:178-237` |
| Calls/min | 最近 600s 中被该源支持的 stable Model Call ID 去重数 ÷ 600 × 60；不是 JSONL 行数、turn 数或 session 数。 | 不提供稳定 call ID 时 `STABLE_MODEL_CALL_ID_UNAVAILABLE`。`Sources/CodingAgentMetricsCore/UsageModels.swift:237-280`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:265-321` |
| TTFT | 所选 performance range（15m/1h/24h/7d）内有效、非 retry 请求的 `ttftMilliseconds` 分布：大号 p50，次行 p95。 | 无可用 request timing；现状会把「该 range 无历史样本」也折叠到 `REQUEST_TIMING_UNAVAILABLE`。`Sources/CodingAgentMetricsCore/Performance.swift:3-25,246-280` |
| E2E | 同一有效非 retry 请求的 `durationMilliseconds` 分布：p50/p95。 | 同 TTFT。`Sources/CodingAgentMetricsCore/Performance.swift:276-280` |
| Decode TPS | 每请求 `(outputTotal - 1) / (durationMilliseconds - ttftMilliseconds)`；仅 `outputTotal ≥ 2`、decode 时间 > 0、非 retry 的请求参与。大号 p50，次行 p10，quality 始终 Derived。 | 没有 request timing，或所有请求不满足 decode 条件；排除数会反映在 coverage。`Sources/CodingAgentMetricsCore/Performance.swift:28-31,246-293` |
| Output Throughput | 最近 180s selected `outputTokens` 总和 ÷ 180，tokens/s。 | 无 observation、filter 排空、源失败/不支持；见第 1 节。 |

`[产品事实]` **n** 不是统一口径：Output/Burn 是贡献 fact 数；Calls 是去重 stable call ID 数；Performance 是进入对应分位数的有效请求数。`n=1…4` 额外提示 Low sample。`Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift:41-50`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:148,234,317`，`Sources/CodingAgentMetricsCore/Performance.swift:94-109,173-176`

`[产品事实]` **source** 是 `sourceAuthority`，并非来源文件名；多 authority/冲突为 `mixed`，无事实为 `unavailable`。**definition** 是版本化 ID（如 `output-throughput-v1`），而非人读定义。**scope** 是 All/Selected，表示是否应用 Agent/Model filter。`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:34-37,457-460`，`Sources/CodingAgentMetricsCore/Domain.swift:224-236`

`[产品事实]` 当前 Summary 有 Agent、Model filter；Activity 以分段控件二选一显示 Burn/Calls；Performance 三张卡和 Output 都各自显示完整 metadata；全局 source health 串列出所有 source，并不严格等同于当前指标的 source。reason/action 现在是文字，唯一实际交互是 Trends、Settings 和 filter。`Sources/CodingAgentMetricsApp/SummaryPopoverView.swift:73-154,255-278,358-473`，`Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift:159-161`

`[产品事实]` `SOURCE_OVERLOADED` 不是模型服务端拥塞：它表示本地 bounded query 被截断或增量 ingestion queue 无法接纳全部 observation；该 source 会不健康、相关指标 partial。`RETENTION_PRUNED` 是历史裁剪导致 coverage partial；容量 hard limit 还会暂停 ingestion。`Sources/CodingAgentMetricsCore/TelemetryRuntime.swift:346-363,421-468,571-607`，`Sources/CodingAgentMetricsCore/Domain.swift:95-97,116-117`

`[产品事实]` 通用无数据建议当前已建模为：无 observation → Wait；filter 排空 → Reduce filter；source failure/overload/schema → Update or restore；能力/stable ID/request timing 缺失 → Enable enhanced telemetry；hard limit → Reset。`Sources/CodingAgentMetricsCore/Domain.swift:54-128`

## 3. Kaboo menu bar TPS 对比

### 证据新鲜度边界

`[Kaboo 当前机器事实]` 本次研究中，所请求的 Kaboo 源树不存在；开发目录、既有本地项目索引与常用 clone 位置也未找到可读检出。因此下面的 Kaboo 列不是本次源码重新核验，也没有新路径或行号。

`[Kaboo 历史研究记录；当前未复核]` 下列内容来自上一轮已完成研究的交接结论。它适合用于设计对比，但版本、实现和默认值均可能已变；在获得源码 revision 前，不应升级为「当前 Kaboo 产品事实」。本次没有用其它已安装菜单栏应用或旧报告冒充新鲜一手证据。

### 历史记录与当前产品对比

| 维度 | coding-agent-metrics `[产品事实]` | Kaboo `[上一轮已记录；当前未复核]` |
|---|---|---|
| TPS 主公式 | 固定 180s 内 selected `outputTokens` 总和 ÷ 180；统一滑动窗口。`Sources/CodingAgentMetricsCore/LiveSampler.swift:10-20`，`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:131-145` | `Σ(window output token deltas) / window wall-clock seconds`。 |
| TPM | 不把 TPS × 60 当作 UI 指标；独立 **Token Burn/min** = 600s 内互斥 input/output/cache/reasoning 消耗总和 ÷ 600 × 60。`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:178-237` | `TPM = TPS × 60`。 |
| 窗口与保留 | Output 固定 3m/180s；趋势 5s bucket。`Sources/CodingAgentMetricsCore/Domain.swift:224-227`，`Sources/CodingAgentMetricsCore/TrendBuilder.swift:65-105` | 默认 3m；可选 3/5/10/15/30m；内存保留 30m。 |
| bucket | 5s，完整 bucket `[start,end)` 才有 value；open bucket 只占位。`Sources/CodingAgentMetricsCore/TrendBuilder.swift:89-105` | 每个完整 5s bucket 为该 bucket output ÷ 5s；只画闭合 bucket。 |
| 并发聚合 | 所有通过 Agent AND Model filter 的 session/model contributions 相加；不平均；同 model-call cohort coalesce 防重。`Sources/CodingAgentMetricsCore/MetricFilter.swift:3-45`，`Sources/CodingAgentMetricsCore/AuthorityCoalescing.swift:13-84` | 所有并发 session/model 的 token delta 进入共同分子；不平均。 |
| 模型 series | 按模型聚合；Top 4，其余合入 Other。`Sources/CodingAgentMetricsCore/TrendBuilder.swift:108-134,217-224` | 按稳定 model identity 建 series；≤5 全画，>5 为 Top 4 + Other；Other 虚线，颜色绑定稳定 identity。 |
| 计数器 | 本文只确认用已归一化 `UsageFact.outputTokens` 聚合；不在报告中声称当前 source 的 message/session cumulative 分摊细节。 | 区分 delta、message-total、session-total；累计值仅在两个观测点齐全时按时间/窗口重叠线性摊分，故应标为 `estimated`。 |
| 更新/发现 | status timer 250ms；light snapshot 约 1s；可见 detail 约 250ms。`Sources/CodingAgentMetricsApp/StatusItemController.swift:206-216`，`Sources/CodingAgentMetricsCore/BoundedRuntime.swift:153-185` | UI poll 1s；discovery 10s；full rescan 2m。 |
| stale | retained 的 last-good facts 会标 Stale；具体由 source health/回填路径决定。`Sources/CodingAgentMetricsCore/SnapshotBuilder.swift:92-150,347-382` | 无新 signal 超过 `max(5m, window)` 为 stale。 |

### 对比结论与限制

- `[设计建议]` 两者的核心可比面是“共同窗口内 token 增量相加，除以共同时间”，都不应被解释为 session 或 model 的平均 TPS；当前产品的 `3m` 固定而 Kaboo 历史记录显示可选窗口。
- `[设计建议]` 当前产品可借鉴 Kaboo 历史记录中的「counter 语义显式化、累计分摊标 estimated、stale 阈值可读化、稳定 identity 色彩」；但要先对 Kaboo 当前 revision 重验，不能以此报告作为实施规格。
- `[Kaboo 当前机器事实]` 要将本节变为一手事实，需提供 Kaboo 的可读源码位置或公开 upstream revision；然后需重新复核公式、默认值和 UI 行为。

## 4. UI 精简建议

### P0

1. `[设计建议]` 默认每项只显示**值 + 单位 + 范围/筛选 + 一行可信度**；仅异常时展开 `Quality · State · Coverage · Updated/Retained`、reason。正常态重复的 `Derived · - · Complete` 不应同时出现在三张 Performance 卡、Activity 和 Output。
2. `[设计建议]` 将一个无数据状态收敛为一处：“原因 + 一个真的 action”。例如 `Enable enhanced telemetry` 进入相应 Settings，`Reset` 执行/确认 reset，`Reduce filter` 聚焦 filter；不要再显示不可点击的 action 文字。当前 reason/action 非按钮是此建议的直接依据。`Sources/CodingAgentMetricsApp/SummaryPopoverView.swift:140-153,467-471`
3. `[设计建议]` 将 Performance 的「范围内无样本」和「未启用 request timing」分开。当前二者会共用 `REQUEST_TIMING_UNAVAILABLE`，会把等待误引导为配置操作。`Sources/CodingAgentMetricsCore/Performance.swift:218-255`
4. `[设计建议]` `Stale · Retained` 的 throughput 不再作为「当前速率」用同等字号展示；改成 `Last known 3m throughput`，同时显示 age，或让主值显示 `No live rate`。否则一个会继续变化的历史窗口很容易被误认为实时 TPS。

### P1

1. `[设计建议]` 把 `source · scope · definition` 放 tooltip/details；只在 `mixed`、Selected 或异常时露出。definition 版本主要用于审计和兼容，不服务即时决策。
2. `[设计建议]` source health 改为「影响当前可见指标的异常源数 + 展开」，替代常驻全局 source ID 串。
3. `[设计建议]` Output 的 `3m` tooltip 明说“最近 180 秒总 output ÷ 180；所有符合筛选的 session/model 相加；不是 Decode TPS”，直接消除最常见误读。

### 不做

- `[设计建议]` 不合并或删除 Quality、State、Coverage、Retained、n：它们分别描述取得方式、值状态、覆盖程度、回填与样本量，代码契约明确它们可独立组合。`Tests/CodingAgentMetricsCoreTests/DegradedDataContractTests.swift:27-67`
- `[设计建议]` 不把 Decode TPS 标成 measured，不把 Calls/min 降格为 observation/turn 数，不把 Output Throughput 改成逐 session 平均；这会违反已经编码的定义和防重语义。

## 验证方式与限制

- 已读取根 `AGENTS.md`、`CONTEXT.md`、research skill 指令与现有研究报告的引用风格。
- 已对照当前 app 的 `SnapshotBuilder`、`LiveSampler`、`TrendBuilder`、`Performance`、`AuthorityCoalescing`、presentation/UI，以及对应 contract/filter/degraded/trend tests；未读取任何真实运行记录。
- 只进行了只读检索和路径存在性检查；本研究不改产品逻辑、不提交、不推送。Kaboo 源树缺失使第 3 节的 Kaboo 内容只能作为带明确新鲜度限制的上一轮研究记录。
