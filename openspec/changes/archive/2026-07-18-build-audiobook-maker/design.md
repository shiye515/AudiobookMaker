## Context

AudiobookMaker 当前只有 Xcode 创建的 SwiftUI/SwiftData 模板，核心业务尚未实现。产品需要在 macOS 26+ 上将 EPUB 解析为章节文本，经本地 TTS 运行时生成音频，再封装为章节 M4B 和整书 ZIP；转换过程必须支持排队、暂停、恢复和异常退出后的断点续传。

实现需遵循 `docs/requirements.md` 的功能边界、`docs/design.md` 的详细设计和 `docs/design-reference.svg` 的视觉参考。App 主体要求使用 Apple 原生技术且不上传书籍内容。CosyVoice3 是非 Apple 的 PyTorch 模型，因此本变更只实现框架无关的 App 侧运行时契约和 mock/XPC 接入层，不实现模型推理进程内部。

## Goals / Non-Goals

**Goals:**

- 用 SwiftUI、SwiftData、Swift Concurrency、Foundation、Compression、AVFoundation、Core Media 和 NSXPCConnection 建立可扩展的原生架构。
- 完成 EPUB 导入、纯文本分章、封面提取、书籍管理和 App 内文件生命周期。
- 完成可持久化的书籍级转换队列、暂停继续、进度、错误处理和断点恢复。
- 用统一 TTS 运行时协议隔离 CosyVoice、Bark、FishSpeech 等框架差异。
- 生成可回读验证的章节 M4B，并将整书产物原子导出为 ZIP。
- 实现符合 Apple HIG、支持键盘、VoiceOver、深浅模式和中英文的 macOS 三栏体验。

**Non-Goals:**

- 不实现 PyTorch/CosyVoice 的安装、下载、加载、GPU 调度和模型推理内部逻辑。
- 不处理 DRM EPUB、复杂图文排版、表格、脚注朗读或损坏文件修复。
- 不实现逐句/逐字时间戳、复杂语音参数编辑、云同步、账号或云端推理。
- 不保证所有第三方播放器都展示 MPEG-4 文本轨；首要兼容目标是 AVFoundation、Apple Books 和 QuickTime Player。

## Decisions

### 1. 采用分层原生架构

代码分为 Presentation、Application、Domain、Infrastructure 四层。SwiftUI View 只发送 intent 并消费不可变 snapshot；Application 协调导入、转换、恢复和导出；Domain 保存状态机、策略和协议；Infrastructure 实现 SwiftData、EPUB、媒体、归档和 XPC。

选择该结构是为了防止界面直接操作文件、SwiftData 或运行时，并使 mock runtime、媒体 spike 和状态机可以独立测试。备选的单体 ViewModel 结构初期文件少，但长任务取消、恢复和跨模块错误会迅速耦合，因此不采用。

### 2. 使用 SwiftData 存元数据，文件系统存大对象

SwiftData schema 包含 Book、Chapter、TTSModel、ConversionJob 和 AppSetting。EPUB、封面、章节 UTF-8 文本、临时音频和 M4B 保存在 `Application Support/AudiobookMaker`，数据库只保存相对路径、哈希、状态和统计字段。

这避免把大文本/音频放入数据库造成迁移、内存和备份压力。外部 EPUB 导入后复制进 App 容器，使恢复不依赖长期 security-scoped bookmark。备选的“始终引用原文件”会受到移动、删除和权限失效影响，因此不采用。

### 3. EPUB 使用受控的 Apple-only ZIP 与 XML 流水线

`ZipContainerReader` 使用 Foundation `FileHandle` 解析 ZIP 目录，使用 Compression 解码 Store/Deflate；`XMLParser` 解析 container、OPF、NAV/NCX 和符合 EPUB 规范的 XHTML，受控提取正文节点并归一化文本，ImageIO 处理封面。这里刻意不使用 `NSAttributedString` 的 HTML importer：后者会触发 WebKit/AppKit 布局工作，不适合后台批量解析，也正是手动测试中 `layoutSubtreeIfNeeded` 控制台诊断的风险来源。

AppleArchive 并非通用 ZIP API；调用 `/usr/bin/ditto` 会增加沙箱和行为稳定性风险；第三方 ZIP 库违反 App 主体不引入第三方依赖的约束。因此实现一个仅覆盖 EPUB 所需子集、带 CRC 和 Zip Slip 防护的组件，并在功能开发前完成兼容性 spike。

### 4. TTS 通过版本化协议和 XPC 边界接入

Domain 定义 `TTSRuntimeClient`，能力包含 health、模型列表、加载、合成和幂等取消。生产 transport 优先使用 NSXPCConnection；DTO 版本化并符合安全编码要求，大音频通过受控临时文件或文件描述符传递，而不是一次性 Data 复制。

能力协商声明支持语言、最大文本长度、输出格式、取消能力和建议并发。App 不根据具体框架写业务分支。相较本地 HTTP/gRPC，XPC 更符合 macOS 沙箱、签名和生命周期管理；若外部运行时只能提供其他协议，可在 XPC broker 后适配，不改变 Domain。

### 5. actor 调度器与显式状态机是唯一任务写入口

`ConversionCoordinator` actor 按 `queueOrdinal` 实现 FIFO，默认并发 1，用户可设为 2，但实际值取用户设置与运行时建议上限的较小值。同一本书章节顺序执行，超长章节按运行时能力切片。

Job 与 Chapter 只能通过显式事件迁移；View 不直接改状态。每个片段、章节封装和任务完成处写 checkpoint。瞬时错误指数退避最多两次，数据/模型错误直接失败。该设计比 OperationQueue 更容易结合 async/await、取消传播和可测试状态机。

### 6. 暂停与恢复优先保证产物一致性

暂停先停止新请求，再取消在途分片，最后持久化 paused；若运行时不支持安全取消，则完成当前分片后暂停。继续从首个未验证完成的分片开始。异常退出时瞬时状态转为 interrupted，启动后验证 partial 与最终产物，并等待用户显式继续，不自动占用大量算力。

只有 M4B 原子落盘并通过回读校验后，Chapter 才能写为 completed。数据库与文件不一致时，以有效且哈希匹配的产物进行修复，避免重复合成。

### 7. M4B 采用两阶段写入和严格回读

运行时 PCM/WAV 先经 AVAudioConverter 统一，再由 AVAssetWriter 写 AAC-LC MPEG-4 容器并使用 `.m4b` 扩展名。每章文件包含音频、书名/作者/章节序号、封面、t=0 章节项和覆盖全时长的单条独立文本轨样本。

输出先写 `.partial`，再用 AVURLAsset 验证音频轨、时长、章节、封面和文本轨，成功后原子改名。不能用 lyrics/comment 元数据替代需求中的文本轨；若 Apple 公共 API 无法满足兼容目标，必须回到需求评审。

### 8. ZIP 导出使用版本化结构并原子提交

整书归档包含按章节顺序命名的 M4B、封面、`metadata.json` 和 `README.txt`。metadata schema 版本化，保存章节顺序、时长、模型与哈希，不重复写入正文。归档在目标目录以隐藏临时文件生成，校验后改名；取消或失败删除临时文件。

### 9. UI 使用系统组件而非自绘仿苹果控件

根界面使用三栏 `NavigationSplitView`：Sidebar 切换书籍/模型，Content 展示列表，Detail 展示章节或模型详情。列表使用 List/Table，状态使用 SF Symbol、文字与 ProgressView；工具栏、搜索、菜单、Settings Scene、快捷键和系统对话框遵循 macOS 习惯。

底部状态区只提供补充队列信息，关键进度同时出现在列表、详情和工具栏。视觉采用系统语义颜色、字体、材质和 Liquid Glass 行为，不叠加自定义玻璃效果。布局在窄窗口按系统规则折叠列。

### 10. Swift 6 严格并发与后台流式 I/O

工程迁移到 Swift 6 严格并发。UI 状态限定 MainActor；后台 SwiftData 写入使用 ModelActor；跨 actor 只传 Sendable DTO、PersistentIdentifier 或值快照。导入、哈希、解压、解析、图片降采样、音频编码和 ZIP 均离开主线程并流式处理。

进度 UI 节流，数据库只在 checkpoint 或显著变化时保存。OSLog signpost 记录阶段耗时但不记录正文。

### 11. 先完成高风险技术预研

完整功能开发前必须验证四项 spike：Foundation/Compression ZIP reader/writer；AVFoundation M4B 章节/封面/文本轨；mock XPC 的大音频、取消和沙箱；Swift 6 + SwiftData ModelActor。失败时调整设计或需求，不在后续实现中静默降级。

## Risks / Trade-offs

- [自研 ZIP 子集可能遇到 EPUB 兼容边缘情况] → 只支持明确方法，使用 EPUB 2/3、ZIP64、异常档案和 Finder Archive Utility 建立测试语料；不支持格式返回可操作错误。
- [MPEG-4 文本轨在播放器间兼容不一致] → 先做媒体 spike，以 AVFoundation、Apple Books、QuickTime Player 为验收矩阵；无法满足时阻断 M5 并进行需求评审。
- [CosyVoice 非 Apple 技术，与“全套苹果技术”存在边界歧义] → App 只依赖协议和 XPC；若推理层也必须 Apple-only，单独评估 Core ML 转换，不把 PyTorch 嵌入 App 主体。
- [SwiftData 状态与文件产物可能因崩溃不一致] → 临时后缀、原子改名、哈希、AVURLAsset 回读和启动恢复共同处理。
- [XPC 大数据复制可能导致内存峰值] → 通过临时文件/文件描述符传递音频，限制请求大小并流式处理。
- [并发 2 可能造成内存、温度或音频吞吐下降] → 默认 1，受运行时 capability 和系统压力限制，设置只表达上限。
- [Swift 5 模板迁移到严格并发会增加初始工作量] → 在 M1 一次完成迁移，并用 actor 边界和 Sendable DTO 避免后期补债。
- [只使用 Apple API 会增加 ZIP/媒体底层实现成本] → 通过 Spike 0 提前验证；组件边界保持可替换，但引入第三方依赖需另行提案。

## Migration Plan

1. 保存当前模板可构建基线，并新增测试 target 与 fixture 目录。
2. 将工程迁移到 Swift 6 严格并发和 macOS 26+，加入 App Sandbox、EPUB 文档类型与 String Catalog。
3. 用 Book/Chapter/TTSModel/ConversionJob/AppSetting schema 替换示例 Item；开发期无真实用户数据，不提供 Item 数据迁移。
4. 完成 Spike 0；任一关键能力未通过则暂停后续里程碑并修订设计。
5. 依次交付原生骨架、EPUB 导入、运行时契约、任务恢复、M4B/ZIP 和 HIG 质量打磨，每阶段保持 mock 端到端流程可运行。
6. 发布前用真实 EPUB 与短 PCM 样本完成性能、安全、可访问性、异常恢复和媒体兼容验收。

回滚策略：每个里程碑保持独立可构建提交；schema 在正式发布前可重建开发数据库。正式发布后若 schema 变化必须增加版本化 migration plan，不删除用户 Application Support 数据。媒体或 ZIP 功能未过验收时保持入口不可用，而不是产出不符合契约的文件。

## Open Questions

- 发布渠道是 Mac App Store、Developer ID 直接分发，还是同时支持；答案会影响运行时与 XPC 的打包、签名和审核方案。
- “全套使用苹果技术”是否包括 TTS 推理层；如果包括，需要单独确认 Core ML 转换后的音质、性能和模型授权。
- M4B 文本轨需要兼容哪些最低播放器集合；当前优先级为 AVFoundation、Apple Books、QuickTime Player。
- EPUB 最大体积、单章最大字符数、总展开大小和压缩比的默认安全阈值需由测试语料冻结。
- AAC 的最终码率需通过语音听感、文件体积和 Apple Books 兼容性测试确定。
