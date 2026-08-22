# macOS 菜单栏 Aggregate TPS：刷新节奏与窗口研究

研究日期：2026-08-22。范围：仅核验公开 GitHub 一手仓库的源码、README 与 issue；不读取真实 usage、模型或 session。本报告区分 **TPS/吞吐量刷新** 与 **配额轮询**，后者不能作为前者证据。

## 结论

- 本轮优先候选中，**没有一个项目能以当前源码同时证明“菜单栏显示 TPS”与其 TPS 公式/窗口/刷新 timer**。因此不能从这些项目得出“菜单栏 aggregate TPS 通常每 N 秒刷新、窗口通常 M 分钟”的经验事实；把配额 API 的 5 分钟轮询写成 TPS cadence 是错误的。
- 可核验的相近项目分成两类：AgentNotch、TokenBar、Claude Status Bar、CodexBar 的菜单栏均监视活动或配额，但不在已定位源码中计算/显示 TPS；其中的 timer 是配额、会话重聚合或动画 timer，应排除。
- 本产品的既有一手实现仍是可用基线：aggregate output throughput 为已选 facts 的 `Σ outputTokens / 180s`；所有筛选命中的 coding-agent / model contribution 相加、不按 session 或 model 平均，并按 `modelCallID` cohort 去重。见 [上一轮产品源码研究](output-throughput-and-kaboo.md)。
- 产品建议：采集 cadence 与菜单栏 display cadence 分离；保留 **5s 的完整 bucket** 用于图，不把它等同于菜单栏数字刷新；菜单栏默认 **30s** 重算并显示 aggregate TPS，默认 window **3m**。

## 证据口径与排除

纳入标准是：一手源码能定位菜单栏 status-item title（或等价 label）且能定位 TPS/throughput 的公式或刷新 timer。仅有 token 总量、会话活动、额度百分比或 provider quota 的项目不进入 TPS 对比；即便有 timer，也只记录为排除依据。

| 项目 / 固定 revision（提交日期） | 菜单栏源码事实 | timer / 聚合事实 | TPS 结论 |
| --- | --- | --- | --- |
| [AgentNotch](https://github.com/AppGram/agentnotch/tree/4139d6fd7b90a060b90b17ed20e0878b0641cc1a)（2026-01-19） | [`MenuBarController.swift:57-64`](https://github.com/AppGram/agentnotch/blob/4139d6fd7b90a060b90b17ed20e0878b0641cc1a/AgentNotch/Window/MenuBarController.swift#L57-L64) 建 status item 并只设 icon；[`MenuBarContentView.swift:76-91`](https://github.com/AppGram/agentnotch/blob/4139d6fd7b90a060b90b17ed20e0878b0641cc1a/AgentNotch/Views/MenuBar/MenuBarContentView.swift#L76-L91) 显示 Last/Recent Tokens。 | [`ClaudeUsageManager.swift:218-233`](https://github.com/AppGram/agentnotch/blob/4139d6fd7b90a060b90b17ed20e0878b0641cc1a/AgentNotch/Core/ClaudeCode/ClaudeUsageManager.swift#L218-L233) 按 setting/smart mode 重新安排单次 timer，调用 `fetchUsage()`；[`162-176`](https://github.com/AppGram/agentnotch/blob/4139d6fd7b90a060b90b17ed20e0878b0641cc1a/AgentNotch/Core/ClaudeCode/ClaudeUsageManager.swift#L162-L176) 是并行拉取 usage。 | **排除**：没有 `tokens / seconds`、窗口或 TPS label；这是 usage/quota refresh，不是 TPS。可配置 interval，但不能推断其值或 TPS cadence。 |
| [TokenBar](https://github.com/Abelliuxl/TokenBar/tree/0e1fc74ea354032cbf3f9ba9696dcedb3ae2db45)（2026-07-17） | [`StatusBarController.swift:14-35`](https://github.com/Abelliuxl/TokenBar/blob/0e1fc74ea354032cbf3f9ba9696dcedb3ae2db45/Sources/TokenBar/StatusBarController.swift#L14-L35) status item 只随 snapshots 刷新 icon。 | [`Poller.swift:10-24`](https://github.com/Abelliuxl/TokenBar/blob/0e1fc74ea354032cbf3f9ba9696dcedb3ae2db45/Sources/TokenBar/Poller.swift#L10-L24) 默认每 **300s** `tickOnce()`；[`58-68`](https://github.com/Abelliuxl/TokenBar/blob/0e1fc74ea354032cbf3f9ba9696dcedb3ae2db45/Sources/TokenBar/Poller.swift#L58-L68) 并行 fetch provider snapshots。 | **排除**：300s 是多 provider quota poll，不是 TPS；无窗口、bucket、`tokens/s` 公式或 menu-bar TPS 文本。 |
| [Claude Status Bar](https://github.com/juzser/claude-status-bar-macos/tree/a0d9b47e0f2952b36c864e4579f5dd6ba5f56043)（2026-08-14） | [`MenuBarLabelView.swift:16-28`](https://github.com/juzser/claude-status-bar-macos/blob/a0d9b47e0f2952b36c864e4579f5dd6ba5f56043/Sources/ClaudeStatusBar/MenuBarLabelView.swift#L16-L28) 由 `labelModel` 合成 status label。 | [`AppState.swift:228-243`](https://github.com/juzser/claude-status-bar-macos/blob/a0d9b47e0f2952b36c864e4579f5dd6ba5f56043/Sources/ClaudeStatusBar/AppState.swift#L228-L243) 文件 watcher 触发会话重聚合，并以 **30s** safety net 重聚合；usage poll 由设置分钟数决定，默认 fallback **5m**。[`TickClock.swift:25-42`](https://github.com/juzser/claude-status-bar-macos/blob/a0d9b47e0f2952b36c864e4579f5dd6ba5f56043/Sources/ClaudeStatusBar/TickClock.swift#L25-L42) 是视觉 ticker。 | **排除**：无 TPS 公式/window；30s 与 ticker 均不能充作 TPS refresh。 |
| [CodexBar](https://github.com/shangmingda/codexbar-macos/tree/effb5d86cb4c834eb60620e80788673bdce53bc5)（2026-07-17） | [`StatusItemView.swift:3-5`](https://github.com/shangmingda/codexbar-macos/blob/effb5d86cb4c834eb60620e80788673bdce53bc5/Sources/CodexBar/StatusItemView.swift#L3-L5) 默认文字是额度状态。 | 已定位 status item，但该 revision 未找到可引用的 TPS timer/公式。 | **排除**：额度/任务监视，不将其当 TPS 实现。 |

本轮也检查了 Tokcat、ClaudeBar、AIQuota、claude-status-bar、KlaudeCrew、cctop 等名称的公开候选；未定位到满足纳入标准的当前 macOS 菜单栏 TPS 源码。它们不作为无证据的“行业通常值”。

## Kaboo：历史记录的证据边界

上一轮报告中的 Kaboo refresh/window/bucket/菜单栏结论没有 upstream URL、revision 或源码行号。本机和公开 GitHub repository 搜索均未找到可读 Kaboo 源树（[API 查询](https://api.github.com/search/repositories?q=kaboo+menu+bar) 返回 `total_count: 0`）。

因此“默认 3m、5s bucket、UI 1s、discovery 10s”等只能标记为 **历史记录，当前未复核**；不可用作本报告的源码事实，也不可作为产品规格。获得公开 revision 或可读源码后，需重新核验。

## 对产品的建议

### 定义与并发

菜单栏 label 应明确为 **Aggregate TPS**，不是 decode TPS：

```text
W = [now - window, now]
aggregate TPS = Σ(selected, deduplicated output token deltas in W) / window seconds
```

- 多个并发 coding-agent、session、model 均进入同一分子；不按 session/model 数平均。
- 用 stable model-call identity 去重；累计计数器必须先转换为时间段内的 token delta，无法可靠拆分时标 `estimated` 或不纳入。
- label 建议 tooltip 直说“selected sessions/models summed; not per-call decode TPS”。

### Cadence 分层

| 层 | 建议 | 原因 |
| --- | --- | --- |
| collector | 尽可能事件驱动；无事件源时 **5s** 采集/归并一次 | 对活跃输出有足够时间分辨率，又避免把 UI 动画误作采集。 |
| chart | **5s completed bucket**；当前 open bucket 只占位 | 不展示不完整分母，避免瞬时 bucket 的假尖峰。 |
| menu-bar display | **30s 默认**；提供 15 / 30 / 60s | 让常驻 label 稳定且轻量；图和详情仍可更快更新。 |
| aggregate window | 默认 **3m**；提供 5 / 10m | 3m 对活跃工作响应快；5m 更平滑；10m 适合低频或稀疏 observation，但对停止/切换反应慢。 |

15s display 对即时感更强、但 label 更跳且会放大观测延迟/补数；30s 是可读性与响应性的平衡；60s 最省电且稳定，但短任务反馈迟缓。display cadence 只控制何时重算/发布 label，不改变 collector、window 或 chart bucket。

## 验证与限制

- 已读取仓库 `AGENTS.md`、`CONTEXT.md`、research skill 与 `docs/research/output-throughput-and-kaboo.md`。
- 已以固定 GitHub commit 链接核验表中行号；没有把 README 宣传语、二手文章或配额轮询升级为 TPS 证据。
- 本研究只新增本报告；未改产品代码、未提交、未推送。
