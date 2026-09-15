## Why

当前章节试听（书籍详情页）与音色试听（音色中心）都通过单实例 `AudioPlaybackService` 播放，但没有任何全局可见的播放状态展示：用户点了试听后，播放状态只隐含在触发按钮自身的图标里；离开触发视图（如从音色中心切回书架）后，既看不到正在播放什么，也无法暂停/恢复，只能重新找到触发点。需要一条悬浮于主窗口底部的播放条，让"正在播放什么、能否暂停"在任何路由下都可见、可控。

## What Changes

- 主窗口新增**悬浮播放条**（floating playback bar）：当存在活跃播放会话（播放中或已暂停未结束）时，以悬浮胶囊形式显示在主内容视图（detail 列）底部，通过 `.safeAreaInset(edge: .bottom)` 呈现，天然规避内容与列表末行遮挡，且不横跨侧边栏，覆盖全部主路由（书架、书籍详情、快速单文本、音色中心、模型面板）。
- 播放条展示**当前播放内容名称与轻量播放进度**：章节试听显示章节名（辅以书名），音色试听显示音色名；同时显示 `mm:ss / mm:ss` 播放时间及底部 2pt 细进度条，避免盲听；章节内容支持点击一键直达对应书籍详情页。
- 播放条提供**播放/暂停切换按钮**（复用 `AudioPlaybackService.togglePause()`）与**停止/关闭按钮**（结束会话并隐藏播放条），出现与隐藏带有顺滑的 Spring 弹簧动效。
- 播放自然播完、解码异常或被替换时，播放条自动清理并隐藏/更新；暂停时保持可见以便恢复。
- `AudioPlaybackService` 增强：挂 `@Observable` 宏保证状态可靠驱动 UI，对内部 `player` 与 `ticker` 添加 `@ObservationIgnored` 隔离非必要刷新；在播放 API 上携带展示元数据（标题/副标题/关联 bookID）；在播完和解码错误回调中统一彻底清理会话。
- 音色试听 10 秒倒计时防竞态管理，到点停止清理会话，避免残留的暂停会话让播放条长期悬挂。

## Capabilities

### New Capabilities

- `playback-bar`: 主窗口底部悬浮播放条——出现/隐藏条件、播放/暂停控制、播放内容名称与轻量进度展示、安全边距自动避让、章节溯源跳转、会话互斥时的内容替换。

### Modified Capabilities

（无。`voice-center` 现有规格"样本最长 10 秒、播放中可停止"与本变更的到点自动结束语义一致，不需要改需求。）

## Impact

- **代码**：`abm/Services/AudioPlaybackService.swift`（@Observable 宏、@ObservationIgnored 属性隔离、展示元数据、播完与解码异常清理）；`abm/Views/MainSplitView.swift`（在 detail 上通过 .safeAreaInset 挂载悬浮播放条与 Spring 动效）；新增 `abm/Views/Player/PlaybackBarView.swift`（胶囊造型、细进度条、时间指示、溯源跳转）；`abm/Core/AppStore.swift`（`playChapter` 传入书名/章节名/bookID）；`abm/Views/VoiceCenter/VoiceLibraryView.swift`（试听到点停止 + 传入音色名 + 防竞态倒计时）。
- **规格**：新增 `openspec/specs/playback-bar/spec.md`（经本变更 delta 归档后）。
- **风险**：`AudioPlaybackService` 挂宏属于对既有观察机制的修正，需回归验证音色试听按钮状态切换与章节试听行为不回退。
