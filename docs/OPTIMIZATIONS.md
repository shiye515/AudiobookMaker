# 优化 backlog（2026-09-14 全面 review 产出）

> 状态：仅记录，未实现。按优先级排列，每项附定位与建议做法。
> 来源：P0–P2 全面 review（对话 2026-09-14）。动工前如涉及行为/规格变化，先走 OpenSpec 提案。

## P0 — 正确性与性能

### 1. 生成期间每个分段全量重写 book.json
- **位置**：`AppStore.updateChapter`（abm/Core/AppStore.swift:590），由 `engine.synthesize` 的每分段进度回调触发。
- **问题**：每段（约 10s）对整本书清单 JSON 重编码 + 原子写盘，50 章的书合成期间上千次主线程磁盘写。
- **建议**：状态迁移（waiting→generating→done）立即存；进度类变更按时间（如 5s）或每 N 段节流。崩溃恢复已有 `reconcile` + 分段断点缓存兜底，节流安全。
- **验收**：合成一本书期间 book.json 写入次数显著下降（可用日志计数），断点恢复行为不回退。

### 2. 零单元测试
- **现状**：无任何测试 target。
- **建议**：新建测试 target，先覆盖纯逻辑：TextChunker（分章/分段）、EPUBParser（XML/路径解析）、LibraryStore.reconcile（四种恢复分支）、AudiobookExporter.safeFileName、FFMETADATA 章节表生成。reconcile 直接关系断点恢复正确性，优先。
- **验收**：`xcodebuild test` 全绿；reconcile 各分支有用例覆盖。

### 3. 日志主线程同步 I/O + 无限增长
- **位置**：`OutputManager.appendLog`（abm/Core/OutputManager.swift:40）。
- **问题**：每行开关一次 FileHandle，调用方多在主 actor；abm.log 无轮转上限。
- **建议**：内部串行队列异步刷写；日志上限（如 10MB）滚动备份。
- **验收**：合成高峰期主线程无日志写盘；日志体积有界。

### 4. 核心持久化静默失败
- **位置**：`try? LibraryStore.save(...)`（abm/Core/AppStore.swift:599）等核心路径的大量 `try?`。
- **建议**：核心持久化（清单保存、音频落盘）改为记日志的 do/catch；边缘路径可保留 `try?`。
- **验收**：人为制造写盘失败（如只读目录）时日志有迹可循。

## P1 — 架构与资源

### 5. AppStore god object（736 行）
- **位置**：abm/Core/AppStore.swift。
- **建议**：按现有 MARK 拆 EngineStore / QueueStore / ExportStore，组合进 AppStore 保持对外接口不变；缩小 @Observable 刷新面。
- **验收**：纯重构，构建通过 + 全功能手测不回退。

### 6. 整章音频驻留内存
- **位置**：engine.synthesize 返回整章 `[Float]`（半小时 ≈ 172MB 峰值）。
- **建议**：分段流式追加写 WAV（分段断点 seg_XXXX.raw 已存在，拼接逻辑顺势改造），峰值压到单段级。
- **验收**：长章节合成时 phys_footprint 峰值明显下降（对照 Telemetry 记录）。

### 7. 存储占用：WAV 无损存放（≈173MB/小时）
- **建议**：可选"合成后即转 M4A 存储"（ffmpeg 已内置，流复制级成本）或提供存储格式设置。导出时本来就转 AAC。
- **验收**：切换开关后新合成章节为 m4a，播放/导出/断点对账兼容两种格式。

### 8. 部署目标 = SDK 版本 26.5
- **位置**：abm.xcodeproj `MACOSX_DEPLOYMENT_TARGET`。
- **问题**：只有最新 macOS 能装；MLX 仅需 macOS 14+。
- **建议**：如在意兼容面降到 15.0（需回归测试）；纯自用可维持现状，但应是明确决策而非随手值。

## P2 — 打磨

### 9. 导出设置不持久化
- **位置**：`AppStore.exportSettings`（目标目录等重启即重置）。
- **建议**：存 UserDefaults。

### 10. 队列静默丢章节
- **位置**：`startNextIfIdle` 音色缺失 `guard ... else { return }`（abm/Core/AppStore.swift:486 附近）。
- **问题**：章节已出队但永不执行、不报错。
- **建议**：标记 failed（含原因）并继续下一章。

### 11. 播放条暂停时 ticker 仍轮询
- **位置**：AudioPlaybackService.ticker 只在 stop 时取消（200ms 轮询）。
- **建议**：pause 挂起 ticker，恢复时重启。

### 12. build-ffmpeg.sh 不校验源码包哈希
- **建议**：对 tarball 加 sha256 校验，防下载劫持与版本漂移。

### 13. 无 CI
- **建议**：GitHub Actions 跑 `xcodebuild build` + 单元测试（见 #2），守住构建绿底线（本次 Release Float16 架构坑若有 CI 早已暴露）。

## 做得好、保持现状

断点恢复设计（checkpoint + reconcile 对账）、显存治理（HANDOFF §11）、OpenSpec 规范流程、ffmpeg 内置化（scripts/build-ffmpeg.sh）、engine actor 串行化。
