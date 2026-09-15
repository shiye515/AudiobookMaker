## Context

播放由单实例 `AudioPlaybackService`（`abm/Services/AudioPlaybackService.swift`，`store.player`，`@MainActor`）承担：`contextID` 标识会话（章节为 `"bookID/chapterID"`，音色样本为 `"voice/…"`），`play()` 自动打断旧会话，`pause()` 保留会话、`stop()` 清空会话。触发点有两处：`AppStore.playChapter(book:chapter:)`（章节试听）与 `VoiceLibraryView`（10 秒音色试听，到点自动暂停）。

两个约束性事实：

1. **`AudioPlaybackService` 的观察机制是失效的**：该类手写 conform 了 `Observable` 协议，但本 SDK 中该协议为空协议、无默认注册逻辑；类上也未挂 `@Observable` 宏、没有 `ObservationRegistrar`。因此 `isPlaying` / `contextID` 等属性的读写既不注册观察也不发通知——现有 `VoiceLibraryView` 的试听按钮状态切换其实是靠其它重渲染"碰巧"刷新的。播放条完全依赖这些属性驱动显隐与图标，必须先修正观察机制。
2. `MainSplitView.swift` 头部注释已宣称承载"底部常驻播放条"，但实现从未落地；本次在该注释所留的位置挂载。

另见 proposal.md 的 Why 与 `playback-bar` delta 规格（出现/隐藏、控制、名称展示、全局可见四条 Requirement）。

## Goals / Non-Goals

**Goals:**

- 播放状态可观察（服务属性变更可靠驱动 SwiftUI，内部 player/ticker 隔离）。
- 一条覆盖全部路由的悬浮播放条：显隐、播放/暂停/停止、内容名称展示。
- 轻量级播放进度指示：底部 2pt 微进度条 + `mm:ss / mm:ss` 播放时间展示。
- 自动避让滚动内容：采用 `.safeAreaInset(edge: .bottom)` 挂载于 detail 主区域，彻底杜绝列表末尾被遮挡，且不横跨侧边栏。
- 播放 API 携带展示元数据（标题/副标题/可选 bookID），支持章节点击溯源直达书籍详情页。
- 异常安全与防竞态：解码错误彻底清理，音色试听 10 秒倒计时防竞态。

**Non-Goals:**

- 不做交互式拖动 seek 滑块、倍速切换、上一/下一章、连播（留待后续独立提案）。
- 不改音色试听"最长 10 秒"的规格语义。
- 不接入系统 Now Playing / 媒体键（MPNowPlayingInfoCenter），后续另行提案。
- 不改 `voice-center`、`book-detail` 等既有规格的基础数据流。

## Decisions

### D1. 播放会话可见性判定 = `contextID != nil`，而非 `isPlaying`

播放条显隐绑定"是否存在活跃会话"。`pause()` 保留 `player`/`contextID`，`stop()` 与播完/异常清理会话，恰好与规格"暂停保持可见、停止/播完隐藏"一一对应。若绑定 `isPlaying`，暂停瞬间播放条会消失、无法恢复播放。
*备选*：新增 `sessionActive` 布尔属性——与 `contextID != nil` 等价，徒增状态，不取。

### D2. `AudioPlaybackService` 改挂 `@Observable` 宏并隔离私有状态

宏会注入 `ObservationRegistrar` 并追踪对外的存储属性，替换掉当前无效的空协议 conformance。同时，对私有属性明确标注 `@ObservationIgnored`：
```swift
@ObservationIgnored private var player: AVAudioPlayer?
@ObservationIgnored private var ticker: Task<Void, Never>?
```
这避免了高频定时器更新 `ticker` 或内部播放器实例替换造成无意义的 Observation 事件。在 nonisolated delegate 回调中，依然通过 `Task { @MainActor in ... }` 安全切换至主线程更新状态。

### D3. 展示元数据与溯源信息由播放方在 `play()` 时传入

`play(url:contextID:)` 增加可选 `title:` / `subtitle:` / `bookID:` 参数（默认 nil），服务保存为 `displayTitle` / `displaySubtitle` / `currentBookID`，`stop()` 与清理时一并清空。
- `playChapter` 传 `(title: chapter.title, subtitle: book.title, bookID: book.id)`；
- 音色试听传 `(title: 音色名, subtitle: "试听样本", bookID: nil)`。
播放条若发现 `currentBookID` 存在，书名/章节名呈现为可点击形态，点击直接切换路由到 `.bookDetail(bookID)`，实现自然闭环。

### D4. 播放条通过 `.safeAreaInset(edge: .bottom)` 挂载于 detail 视图

放弃整窗 `overlay`，改为在 `MainSplitView` 的 `detailContent` 上挂载 `.safeAreaInset(edge: .bottom)`：
1. **天然防遮挡**：SwiftUI 自动为 detail 内的 `Table`（如章节列表末行操作按钮）和 `ScrollView`（如书架末排卡片）增加底部安全内边距，列表滑到底部时内容停在播放条上方，彻底杜绝死角遮挡。
2. **布局协调**：胶囊居中于 detail 内容区（宽度上限 ~560pt），不再横跨侧边栏分割线，视觉层级分明。
3. **动效精致**：搭配 `.animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.contextID != nil)` 与 `.transition(.move(edge: .bottom).combined(with: .opacity))`，呈现原生丝滑的弹出与收起。

### D5. 播完与解码异常均彻底清理会话（自动隐藏）

在 `audioPlayerDidFinishPlaying`（自然播完）与 `audioPlayerDecodeErrorDidOccur`（解码异常）中，统一调用 `self.stop()`，清理 `contextID`、元数据并取消定时器。播放条随之自动隐藏，防止异常时播放条永久悬挂无法关闭。

### D6. 音色试听 10 秒倒计时防竞态管理

在 `VoiceLibraryView` 中维护当前试听倒计时的 `Task` 句柄，启动新试听时立即取消前一个未完成的倒计时 Task，到点调用 `player.stop()` 彻底结束会话。杜绝快速连续试听多个音色时旧 Task 倒计时竞态误杀新音频。

### D7. 微进度条与播放时间指示

在 `PlaybackBarView` 底部内嵌一条 2pt 高度的细进度条（按 `currentTime / duration` 比例绘制，已播段采用强调色），并在副标题右侧展示 `mm:ss / mm:ss` 时间文本。由于 `AudioPlaybackService` 已有 `currentTime` 和 `duration`，此轻量展示直接受益，既赋予用户对播放进度的清晰掌控感，又避免引入复杂的拖动交互。

## Risks / Trade-offs

- [@Observable 宏改动波及既有视图] → 回归验证两处触发点：章节试听按钮行为、音色中心"试听/停止"图标切换（属修复而非回归）。
- [悬浮条遮挡底部内容] → 通过 `.safeAreaInset(edge: .bottom)` 从框架层面彻底消除，滚动容器自动避让。
- [并发与竞态] → 属性读写收敛在 `@MainActor`，音色试听任务主动持有并取消，保证时序严格安全。

## Migration Plan

纯 UI + 播放服务增强，无数据迁移、无外部依赖变化。回滚即删除 `PlaybackBarView` 与相关挂载/参数，`@Observable` 宏改动可独立回退（回退后播放条显隐失效，故一并回退）。

## Open Questions

（无。）
