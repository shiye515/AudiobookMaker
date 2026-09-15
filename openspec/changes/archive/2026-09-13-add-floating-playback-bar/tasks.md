## 1. 播放服务：可观察性、状态隔离与异常安全

- [x] 1.1 `AudioPlaybackService` 挂 `@Observable` 宏并移除无效的空 `Observable` 手写 conformance；对私有存储属性 `player` 和 `ticker` 显式标注 `@ObservationIgnored`（design D2），运行编译验证
- [x] 1.2 `play(url:contextID:)` 增加可选 `title` / `subtitle` / `bookID` 参数并新增 `displayTitle` / `displaySubtitle` / `currentBookID` 存储属性，`stop()` 一并清空（design D3）
- [x] 1.3 统一异常与播完清理：在 `audioPlayerDidFinishPlaying`（自然播完）与 `audioPlayerDecodeErrorDidOccur`（解码错误）中均调用 `self.stop()` 彻底复位会话并清空元数据（design D5）

## 2. 播放方元数据传入与防竞态定时器

- [x] 2.1 `AppStore.playChapter` 调用 `player.play` 时传入 `title: chapter.title, subtitle: book.title, bookID: book.id`，支持溯源跳转
- [x] 2.2 `VoiceLibraryView` 音色试听传入 `title: voice.name, subtitle: "试听样本"`；在视图中管理试听 Task 句柄，启动新试听时取消前次 Task，到点执行 `player.stop()`，彻底消除并发竞态（design D6）

## 3. 播放条视图与 safeAreaInset 避让挂载

- [x] 3.1 新建 `abm/Views/Player/PlaybackBarView.swift`：
  - 胶囊造型（`.ultraThinMaterial` 背景 + 细微边框 + 阴影）；
  - 播放/暂停切换按钮与停止关闭按钮；
  - 主标题 + 副标题展示，当存在 `currentBookID` 时支持点击直达对应书籍详情；
  - 底部 2pt 细微进度条（跟随 `currentTime / duration` 动态比例）+ `mm:ss / mm:ss` 极简时间显示；
  - 静态/微动态波形视觉指示。
- [x] 3.2 在 `MainSplitView` 的 `detailContent` 上以 `.safeAreaInset(edge: .bottom)` 挂载 `PlaybackBarView`，添加 Spring 弹簧动效与 move+opacity 进出场过渡（design D4），验证：
  - 悬浮胶囊居中且不横跨侧边栏分割线；
  - 章节列表、书架卡片滑至最底端时自动上移避让，末行操作按钮完全可见无遮挡。

## 4. 构建与规格回归走查

- [x] 4.1 全量构建通过：`xcodebuild -project abm.xcodeproj -scheme abm build`
- [x] 4.2 按 `playback-bar` delta 规格逐条走查：
  - ① 章节试听/音色试听后播放条以弹簧动效优雅浮现；
  - ② 暂停后播放条保持可见，点击可随时恢复；
  - ③ 自然播完或解码异常后自动隐藏；
  - ④ 停止按钮结束会话并隐藏；
  - ⑤ 章节试听显示章节名+书名并可点击跳转，音色试听显示音色名+试听样本；
  - ⑥ 播放条实时展示微进度条与 `mm:ss / mm:ss` 播放时长；
  - ⑦ 快速连续切换音色试听无倒计时竞态误关；
  - ⑧ 跨路由切换播放不中断且持续可见；
  - ⑨ 滚动至章节列表最底部，末行操作按钮不被遮挡。
