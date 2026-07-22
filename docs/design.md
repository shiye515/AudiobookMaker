# AudiobookMaker 设计方案

> 设计版本：v0.1  
> 对应需求：[requirements.md](./requirements.md) v0.1  
> 目标平台：macOS 26+ 原生应用  
> 设计原则：本地优先、Apple 原生技术栈、符合 macOS Human Interface Guidelines

---

## 1. 设计结论

AudiobookMaker 采用纯原生 macOS 架构：SwiftUI 负责界面，SwiftData 负责业务数据，Swift Concurrency 负责后台任务与并发，Foundation / Compression 负责 EPUB 和 ZIP，AVFoundation / Core Media / AudioToolbox 负责音频编码与 M4B 容器，NSXPCConnection 作为未来本地推理运行时的首选进程边界。

应用主体不引入 Electron、WebView、跨平台 UI、第三方数据库、第三方网络层或第三方设计系统。AppKit 仅用于 SwiftUI 尚未覆盖的原生 macOS 能力，仍属于 Apple 技术栈。

Kokoro 通过随 App 分发的双架构 sherpa-onnx 与 ONNX Runtime 执行。模型权重不编译进 App，而是在用户明确操作后下载到 Application Support：

- App 内所有业务与 UI 保持 Apple 原生实现。
- App 只依赖 `TTSRuntimeClient` 抽象，不直接依赖 Python、PyTorch 或具体模型框架。
- 正式运行时优先通过内嵌 XPC Service 接入。
- 如果后续要求“推理层也必须全 Apple”，则必须先将模型转换并验证为 Core ML 可运行版本；这应作为独立技术预研，不在当前范围内。

### 1.1 已确定的产品决策

| 议题 | 设计决策 |
|---|---|
| 默认并发数 | 1；设置中允许调整为 1 或 2，运行时可根据能力将上限收紧 |
| EPUB 源文件 | 导入后复制到 App 的 Application Support；不持续依赖外部文件权限 |
| 删除书籍 | 删除 App 管理的副本、解析文本、临时文件及音频产物；绝不删除用户原始 EPUB |
| 断点恢复 | 完成章节不重做；异常退出时正在转换的章节回到“待继续”，由用户显式继续，避免重启后突然占用算力 |
| 音频格式 | AAC-LC 音频写入 MPEG-4 容器，文件扩展名为 `.m4b` |
| 每章产物 | 一个 M4B；包含 t=0 章节项、封面、书籍/作者元数据和覆盖整章时长的单条文本轨样本 |
| 导出格式 | 单个 `.m4b`；合并全书音频时间轴，并内嵌章节导航、封面和书籍元数据 |
| 设置入口 | 使用标准 macOS `Settings` Scene 和 `⌘,`，不在工具栏放齿轮按钮 |

---

## 2. 目标与非目标

### 2.1 设计目标

1. 用户可以通过文件选择或拖放导入 EPUB，并清楚看到解析结果。
2. 转换是可观察、可暂停、可恢复的长任务，任何耗时操作都不阻塞主线程。
3. 任务与产物在 App 重启后可恢复，已完成章节不会重复生成。
4. UI 在大窗口、窄窗口、全屏、深浅色模式和辅助功能环境中均保持原生 macOS 行为。
5. Apple 系统语音与 Kokoro 通过统一协议接入，App 业务层不感知底层框架差异。
6. 文件结构和媒体产物可验证、可重建、可定位，不把大段文本和音频二进制直接塞进数据库。

### 2.2 非目标

- 不允许把 Kokoro 权重、`voices.bin` 或模型词典编译进 App bundle；模型安装必须校验签名清单、大小、SHA-256、路径和必需文件。
- 不处理 EPUB 的复杂排版、表格、脚注、图片朗读、DRM 或损坏文件修复。
- 不实现逐句时间戳、逐字高亮、复杂音色/语速/语调编辑。
- 不提供云同步、账号系统或云端推理。
- 不承诺第三方播放器都展示文本轨；产物首先以 Apple Books、QuickTime Player 和 AVFoundation 可读为验收目标。

---

## 3. Apple 原生技术选型

| 能力 | 技术 | 用法 |
|---|---|---|
| UI | SwiftUI | `NavigationSplitView`、`List`、`Table`、`ProgressView`、`ContentUnavailableView`、`Settings` |
| 少量平台桥接 | AppKit | 必要时接入原生窗口、菜单或尚无 SwiftUI 等价能力的 API |
| 状态观察 | Observation | `@Observable` 展示层状态，避免把瞬时 UI 状态写入 SwiftData |
| 持久化 | SwiftData | Book、Chapter、TTSModel、ConversionJob、AppSetting |
| 并发 | Swift Concurrency | actor、structured concurrency、`AsyncStream`、取消传播 |
| 数据隔离 | SwiftData `ModelActor` | 后台导入、队列写入和状态更新串行化 |
| 文件导入 | UniformTypeIdentifiers | `UTType.epub`，配合 SwiftUI `fileImporter` 和 `dropDestination` |
| EPUB 解包 | Foundation + Compression | 读取 ZIP 中央目录，支持 Store/Deflate，防 Zip Slip |
| EPUB XML | Foundation `XMLParser` | 解析 `container.xml`、OPF、NAV/NCX |
| XHTML 转纯文本 | Foundation `XMLParser` | 受控读取 EPUB XHTML 正文，跳过脚本/样式/隐藏节点后统一空白、段落和 Unicode；避免 HTML importer 的主线程布局副作用 |
| 图片 | ImageIO / CoreGraphics | 封面格式识别、解码、缩略图生成和尺寸限制 |
| 音频 | AVFoundation / AudioToolbox | PCM/WAV 校验、AAC 编码、音频时长与元数据 |
| 容器与轨道 | AVFoundation / Core Media | M4B、章节关联、文本样本、封面和通用元数据 |
| 运行时 IPC | Foundation `NSXPCConnection` | 模型状态、加载、合成、取消和错误回传 |
| 哈希 | CryptoKit | 源文件指纹、文本指纹、产物完整性校验 |
| 日志 | OSLog | 分类日志、隐私标记和性能 signpost |
| 测试 | Swift Testing + XCTest/XCUITest | 领域单测、媒体集成测试、UI/可访问性测试 |

### 3.1 语言与工程设置

- 新代码采用 Swift 6 语言模式和严格并发检查。
- UI 状态默认限定在 `@MainActor`。
- 跨 actor DTO 必须符合 `Sendable`；不跨 actor 传递 SwiftData 模型实例，只传 `PersistentIdentifier` 或值类型快照。
- 当前工程的 `SWIFT_VERSION = 5.0`，实现 M1 前应迁移并清理并发警告。
- 当前工程的 deployment target 为 macOS 26.5；产品基线建议设为 macOS 26.0，具体小版本由发布策略决定。

---

## 4. 总体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ Presentation                                                 │
│ SwiftUI Views · @Observable View State · Commands · Settings │
└──────────────────────────────┬───────────────────────────────┘
                               │ intents / snapshots
┌──────────────────────────────▼───────────────────────────────┐
│ Application                                                  │
│ LibraryService · ImportCoordinator · ConversionCoordinator   │
│ ExportCoordinator · ModelCatalogService                      │
└───────────────┬──────────────────────┬───────────────────────┘
                │                      │
┌───────────────▼─────────────┐  ┌─────▼───────────────────────┐
│ Domain                      │  │ Persistence & File Storage  │
│ Entities · States · Policies│  │ SwiftData ModelActor        │
│ Runtime contracts · Errors  │  │ Application Support layout  │
└───────────────┬─────────────┘  └─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────┐
│ Apple Infrastructure                                        │
│ EPUBReader · ImagePipeline · M4BPackager · ZipExporter      │
│ XPC TTSRuntimeClient · OSLog                                │
└─────────────────────────────────────────────────────────────┘
```

依赖方向必须从外向内：View 可以依赖 Application，Application 可以依赖 Domain 协议，但 Domain 不依赖 SwiftUI、SwiftData、AVFoundation 或具体 TTS 框架。

### 4.1 建议目录

```text
AudiobookMaker/
├── App/
│   ├── AudiobookMakerApp.swift
│   ├── AppCommands.swift
│   └── DependencyContainer.swift
├── Features/
│   ├── Library/
│   ├── BookDetail/
│   ├── Models/
│   ├── Queue/
│   └── Settings/
├── Domain/
│   ├── Models/
│   ├── States/
│   ├── Policies/
│   └── Runtime/
├── Application/
│   ├── ImportCoordinator.swift
│   ├── ConversionCoordinator.swift
│   ├── ExportCoordinator.swift
│   └── RecoveryCoordinator.swift
├── Infrastructure/
│   ├── Persistence/
│   ├── EPUB/
│   ├── Media/
│   ├── Archive/
│   ├── RuntimeXPC/
│   └── Logging/
└── Resources/
    ├── Assets.xcassets
    └── Localizable.xcstrings
```

---

## 5. 数据设计

### 5.1 SwiftData 实体

#### Book

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID，unique | 稳定主键 |
| title / author | String | 从 OPF 读取；缺失时显示“未知作者” |
| importedAt / updatedAt | Date | 导入和最近状态更新时间 |
| sourceRelativePath | String | App 管理的 EPUB 副本 |
| sourceSHA256 | String | 去重和完整性校验 |
| coverRelativePath | String? | 原始或规范化封面 |
| languageCode | String? | EPUB 元数据语言 |
| statusRaw | String | 聚合后的 BookStatus |
| totalChapters / completedChapters | Int | 快速列表展示 |
| totalCharacters | Int64 | 估算工作量 |
| chapters | [Chapter] | cascade delete |
| jobs | [ConversionJob] | cascade delete |

#### Chapter

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID，unique | 稳定主键 |
| book | Book | 反向关系 |
| index | Int | spine 顺序，从 0 开始 |
| title | String | NAV/NCX 标题，缺失时生成“第 N 章” |
| textRelativePath | String | UTF-8 纯文本文件，不在数据库保存大文本 |
| textSHA256 | String | 判断产物是否与文本匹配 |
| characterCount | Int | 进度权重与切片依据 |
| statusRaw | String | ChapterStatus |
| artifactRelativePath | String? | 最终 M4B 路径 |
| durationSeconds | Double? | 实际音频时长 |
| attemptCount | Int | 重试次数 |
| lastErrorCode / lastErrorMessage | String? | 可诊断错误；不得保存原文 |
| updatedAt | Date | 恢复与排序使用 |

#### TTSModel

| 字段 | 类型 | 说明 |
|---|---|---|
| id | String，unique | 如 `sherpa-onnx/kokoro-multi-lang-v1_1-int8` |
| displayName | String | 本地化展示名 |
| frameworkRaw | String | avFoundation / sherpaOnnx / unknown |
| source | String? | 仓库或本地来源，仅展示 |
| isDefault | Bool | 全局只能有一个 |
| installationRaw | String | unavailable / installed / invalid |
| runtimeRaw | String | unloaded / loading / ready / failed |
| capabilitiesData | Data? | 版本化 Codable 能力快照 |
| lastValidatedAt | Date? | 最近运行时握手时间 |

#### ConversionJob

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID，unique | 队列项 |
| book | Book | 所属书籍 |
| modelID | String | 创建任务时固定模型，防止中途切换造成音色混用 |
| stateRaw | String | JobState |
| priority | Int | 首版统一为 0，预留调整 |
| queueOrdinal | Int64 | 持久化 FIFO 顺序 |
| createdAt / startedAt / finishedAt | Date? | 生命周期 |
| completedUnits / totalUnits | Int64 | 以字符数为主要进度单位 |
| lastHeartbeatAt | Date? | 判断非正常中断 |
| errorCode / errorMessage | String? | 任务级错误 |

#### AppSetting

首版仅保留单例设置：`maxConcurrentJobs`、`selectedModelID`、`keepIntermediatePCM`、`lastExportDirectoryBookmark`。默认并发为 1；`keepIntermediatePCM` 默认关闭。

### 5.2 状态枚举

```swift
enum ChapterStatus: String, Codable, Sendable {
    case pending, queued, synthesizing, packaging
    case paused, completed, failed
}

enum JobState: String, Codable, Sendable {
    case queued, preparing, running, pausing, paused
    case completing, completed, failed, cancelled, interrupted
}

enum BookStatus: String, Codable, Sendable {
    case ready, queued, converting, paused, completed, failed
}
```

状态只能由 `ConversionCoordinator` 通过显式事件迁移，View 不直接修改状态字段。

### 5.3 关键状态机

```text
Job:
queued → preparing → running → completing → completed
                     │   │
                     │   └→ failed → queued (retry)
                     └→ pausing → paused → queued (continue)

App 异常退出：preparing/running/pausing/completing → interrupted
恢复操作：interrupted → queued

Chapter:
pending → queued → synthesizing → packaging → completed
                    │              │
                    ├→ paused      └→ failed
                    └→ failed
```

持久化顺序必须保证：先原子落盘 M4B，再将 Chapter 标记为 `completed`。如果数据库显示未完成但有效产物已存在，恢复协调器可通过哈希和媒体校验补记完成状态。

---

## 6. 文件与目录设计

所有内部路径相对于 `Application Support/AudiobookMaker` 保存，数据库不保存绝对路径。

```text
Application Support/AudiobookMaker/
├── Books/{bookUUID}/
│   ├── source.epub
│   ├── cover/original.{ext}
│   ├── text/0000.txt
│   ├── text/0001.txt
│   ├── audio/0001-title.m4b
│   └── work/{chapterUUID}/
│       ├── request.json
│       ├── synthesis.partial
│       └── package.partial
├── Runtime/
└── Logs/                  # 仅开发构建可选，不含书籍正文

Caches/AudiobookMaker/
└── Imports/{operationUUID}/
```

规则：

- 导入先复制至临时目录，校验与解析成功后再原子移动到正式目录。
- `.partial` 文件永远不作为完成产物；恢复时可以安全删除或继续。
- 文件名仅用于可读性，身份由 UUID 与数据库关系决定。
- 生成 Finder 可见文件名时清理 `/`、`:`、控制字符和首尾空白，并限制长度。
- 删除书籍采用“先移动到 App 内 Trash 暂存，再删数据库”的顺序；当前会话可提供撤销。最终清理由后台执行。

---

## 7. EPUB 导入与解析

### 7.1 导入入口

- 工具栏“导入 EPUB”使用 `fileImporter(allowedContentTypes: [.epub], allowsMultipleSelection: true)`。
- 主内容空态和书籍列表都接受 Finder 拖入；只在拖入有效 EPUB 时显示系统强调色描边。
- 文件选择返回的 security-scoped URL 只在复制期间访问，使用 `defer` 成对结束访问。
- 同一 SHA-256 的文件再次导入时不静默复制，弹出原生确认：定位已有书籍或仍然创建副本。

### 7.2 解析流水线

```text
选择/拖入
  → 文件类型、大小和可读性校验
  → SHA-256
  → 安全解包到临时目录
  → META-INF/container.xml
  → package.opf manifest + metadata + spine
  → NAV（优先）/ NCX（回退）生成章节标题
  → spine 文档 HTML → 纯文本
  → 封面发现与解码
  → SwiftData 批量写入
  → 原子提交书籍目录
```

### 7.3 Apple-only ZIP 读取器

AppleArchive 处理的是 Apple Archive 格式，不等同于通用 ZIP。为了不引入第三方库，设计一个范围受控的 `ZipContainerReader`：

- Foundation `FileHandle` 解析 EOCD、中央目录和本地文件头。
- 首版仅支持 EPUB 常用的 Store（0）和 Deflate（8）。
- Deflate 使用 Compression 的 `COMPRESSION_ZLIB` 流式解码。
- 拒绝加密条目、多磁盘 ZIP、超大展开比例、无效 CRC 和不支持的压缩方法。
- 规范化每个条目路径，拒绝绝对路径、`..`、符号链接和任何逃逸临时目录的目标，防止 Zip Slip。
- 对总展开大小、单文件大小、文件数和压缩比设置上限；具体默认值在实现阶段通过真实样本确定。

ZIP 导出复用同一底层组件的 writer，但只需支持 Store/Deflate、UTF-8 文件名和 ZIP64 的受控子集。该组件应先以 EPUB 官方样本和大文件做独立技术验证。

### 7.4 分章规则

1. 以 OPF spine 顺序为事实来源。
2. 以 EPUB 3 NAV 标题为首选，EPUB 2 NCX 为回退。
3. 同一 spine item 内的多个锚点首版不再细切，避免重复抽取正文。
4. 空文本 spine item 跳过，但记录解析 warning。
5. 章节标题缺失时生成本地化标题“第 N 章”。
6. HTML 转纯文本后保留段落边界，连续空白归一化为单空格，连续空行最多保留一行。
7. 使用 Unicode Normalization Form C；不擅自转换简繁体或改写标点。
8. 超长章节只在发送运行时时内部切片，最终仍合并为一个章节 M4B。

---

## 8. TTS 运行时边界

### 8.1 App 侧协议

```swift
protocol TTSRuntimeClient: Sendable {
    func health() async throws -> RuntimeHealth
    func listModels() async throws -> [RuntimeModel]
    func loadModel(id: String) async throws -> LoadedModel
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult
    func cancel(requestID: UUID) async
}
```

`SynthesisRequest` 至少包含：`requestID`、`chapterID`、`segmentIndex`、`text`、`modelID`、`languageCode`、默认语音参数、期望 PCM/WAV 格式、文本 SHA-256。`SynthesisResult` 包含音频临时文件句柄或共享容器相对路径、采样率、声道数、帧数、运行时版本和模型版本。

### 8.2 XPC 契约

- 使用 `NSXPCConnection` 和版本化 DTO；所有跨进程对象采用值语义与 `NSSecureCoding`。
- 大音频不通过 Data 一次性复制，使用受控临时文件或文件描述符传递。
- XPC 中断、失效和超时映射为领域错误，不把底层异常直接展示给用户。
- 取消必须幂等；暂停时先停止发新分片，再取消在途请求，最后保存 checkpoint。
- App 启动时先握手版本与能力；不兼容时模型显示“需要更新运行时”，转换按钮禁用。
- 日志只记录 requestID、耗时、帧数和错误码，不记录章节原文。

### 8.3 多框架适配

App 不根据框架写分支逻辑。运行时通过 `RuntimeCapabilities` 声明：支持语言、最大文本长度、输出格式、可取消性、参数集合和建议并发。`ConversionCoordinator` 只依据能力切片与调度。

内置模型目录包含 Apple 系统语音、Kokoro、CosyVoice3 与 Qwen3-TTS 描述记录，但不包含任何模型权重。后两者只在原生 Apple Silicon、macOS 15+ 且 Metal 可用时展示下载操作；Intel/Rosetta 显示“需要原生 Apple Silicon”。模型只有在签名清单校验、逐 artifact 安装、内容收据和离线运行时探测成功后才显示“可用”。“设为默认”和音色切换只改变后续新任务；运行中的任务继续使用创建时锁定的 model ID、version 与 voice ID。

speech-swift 0.0.23 与 MLX Swift 版本由 `Package.resolved` 固定。CosyVoice3 和 Qwen3-TTS 只从 Application Support 下已验证的 snapshot 以 offline 模式加载；缺文件不得触发 Hub 下载。两者声明高内存、并发 1 和安全片段取消边界。Qwen3-TTS 在句子边界二次切至最多 120 字符，CosyVoice3 最多 180 字符；当前片段完成前暂停可能不是即时的，完成后的晚到 PCM 在取消/超时后丢弃。模型切换先等待共享生成槽，再释放旧 session，防止两份权重同时驻留。

---

## 9. 转换队列与断点续传

### 9.1 调度器

`ConversionCoordinator` 是 actor，持有内存中的活跃任务表，SwiftData `ModelActor` 是持久化真相源。

调度规则：

1. FIFO，按 `queueOrdinal` 排队。
2. 默认最多运行 1 本书；设置允许 2，但不得超过运行时 `recommendedConcurrency`。
3. 同一本书内章节顺序执行，保证音色上下文和资源占用可预测。
4. 每章内部按运行时最大文本长度切片，片段顺序合并。
5. 每个重要边界都落 checkpoint：请求前、片段完成、章节封装完成、任务完成。
6. 失败默认不无限重试；瞬时错误指数退避最多 2 次，模型/数据错误立即失败并给出操作建议。

### 9.2 暂停语义

- 点击暂停后 UI 立即进入“正在暂停”，禁止重复点击。
- 停止创建新请求，取消当前分片；保留此前已完成分片。
- 运行时确认取消或超时后，将 Job/Chapter 持久化为 paused。
- 继续时从首个未验证完成的分片开始。
- 如果运行时不支持安全取消，能力中必须声明；此时暂停在当前分片结束后生效，UI 显示“完成当前片段后暂停”。

### 9.3 进度计算

- 书籍总进度按完成字符数 / 总字符数计算，避免长短章节权重相同。
- 正在合成的单章若运行时没有精确进度，显示不确定进度；章节完成后总进度跳至确定值。
- 列表、详情和底部状态区读取同一个不可变 `QueueSnapshot`，避免显示不一致。

### 9.4 启动恢复

1. 扫描处于瞬时状态的 Job/Chapter，标记 interrupted。
2. 清理不可恢复的 `.partial`，验证可复用分片与最终 M4B。
3. 对完成产物使用 AVURLAsset 校验音频轨、可播放性、时长和元数据。
4. 在界面顶部显示“有 N 个任务可以继续”，不自动开始高负载推理。
5. 用户选择继续后重新握手模型版本；模型改变时提示可能导致声音不一致。

---

## 10. M4B 封装设计

### 10.1 两阶段流水线

```text
运行时 PCM/WAV 分片
  → 格式/采样率校验
  → AVAudioConverter（必要时统一格式）
  → AVAssetWriter 写 AAC-LC 音频
  → 写容器元数据、章节轨和文本轨
  → 临时 M4B
  → AVURLAsset 回读验收
  → 原子移动为最终 M4B
```

建议输出参数首版固定为 AAC-LC、单声道、44.1 kHz、64–96 kbps；最终值需以真人语音样本进行听感、文件大小和 Apple Books 兼容性验证后冻结。

### 10.2 容器与元数据

AVFoundation 以 MPEG-4 Audio 类型创建容器，最终使用 `.m4b` 扩展名。写入：

- title：章节标题
- artist：书籍作者
- albumName：书名
- trackNumber：章节序号 / 总章节数
- artwork：封面图片
- description：由 AudiobookMaker 生成，不包含整章原文
- copyright / language：源 EPUB 存在时写入

每章文件只有一个章节，因此章节列表轨在 `t=0` 写入一个标题项，并将该轨与音频轨建立 chapter association。

### 10.3 文本轨

需求要求“整段章节文字作为一个文本轨，无逐句时间戳”。实现为独立 text track：

- 单个文本样本，起点为 0，duration 等于音频总时长。
- UTF-8 正文保持与 `Chapter.textSHA256` 对应。
- 文本轨与主音频轨建立关联，不把正文仅写进 comment 或 lyrics 字段来冒充文本轨。

AVFoundation 能创建和关联媒体轨，但不同播放器对 MPEG-4 文本轨的展示能力不同。M5 开始前必须完成一个 media spike：分别用 AVURLAsset、QuickTime Player、Apple Books 和 `mdls`/媒体检查工具验证章节、封面、文本轨和 `.m4b` 扩展名。若 Apple 公共 API 无法生成满足要求的可读文本轨，应回到需求评审，不能静默降级为普通元数据。

### 10.4 产物验收

只有同时满足以下条件才标记 Chapter completed：

- 文件存在且非零；无 `.partial` 后缀。
- AVURLAsset 可加载，存在 1 条可播放音频轨。
- 实际时长大于 0，且与记录时长误差在容许范围内。
- 封面、title、artist、albumName 存在。
- 存在 t=0 章节项和独立文本轨。
- 文本哈希、模型 ID、运行时版本写入旁车校验记录。

---

## 11. 单文件 M4B 导出设计

用户对已完成书籍执行“导出有声书…”，使用原生保存面板选择目标位置和 `.m4b` 文件名。导出在后台执行，并显示可取消的确定进度。

```text
Book Title.m4b
├── AAC-LC 单一音频时间轴
├── 带起止时间的章节文本轨（chapterList 关联）
├── 封面艺术
└── 标题、作者、旁白者、类型、出版日期与语言元数据
```

导出器按阅读顺序将每章已有 M4B 解码并标准化，再合并到连续时间轴；每章标题作为独立定时样本写入章节轨，使播放器可以跳转。封面及书籍元数据直接写入 MPEG-4 容器，不生成旁车文件。

导出先在 App 缓存目录写临时文件，使用 AVFoundation 回读校验音频轨、章节顺序、标题和封面后再提交到用户选择的位置。取消或失败时删除临时文件；同名覆盖由系统保存面板确认。书签及 iCloud 收听位置由支持 M4B 的播放器（例如 Apple Books）管理；变速且不变调同样属于播放器播放能力，文件保持标准 AAC 音频，不预先改变音速或音调。

---

## 12. macOS 界面设计

### 12.1 信息架构

使用三栏 `NavigationSplitView`：

```text
┌ Sidebar ─────┬ Content/List ──────────┬ Detail ─────────────────────┐
│ 书籍          │ 书籍列表                │ 书籍信息 + 章节 + 任务控制     │
│ 模型          │ 模型列表                │ 模型能力 + 状态 + 设为默认     │
│               │                        │                             │
└──────────────┴────────────────────────┴─────────────────────────────┘
  补充状态区：队列 2 · 转换中 1 · 已完成 8 · [查看队列]
```

- Sidebar：建议 180–240 pt，可由用户隐藏；使用系统 sidebar list style。
- Content：建议 300–420 pt，使用 List/Table，不用大面积自绘卡片。
- Detail：最小 520 pt，随窗口伸缩，承载主要操作。
- 窗口建议最小 980 × 640 pt；默认约 1180 × 760 pt，记忆用户窗口尺寸与栏宽。
- 窄窗口允许系统折叠列，不通过固定 frame 强行保持三栏。

### 12.2 Sidebar

仅放稳定的一级导航：

- `books.vertical` 书籍
- `waveform` 模型

队列不是第三个业务域，首版通过工具栏状态按钮、底部补充状态区和 Window 菜单中的“显示队列”进入。导航项同时提供文字，不能只显示图标。

### 12.3 书籍列表

列表行包含：

- 48 × 64 pt 封面缩略图，使用 4 pt 连续圆角；无封面时为系统占位图。
- 主标题一行，作者一行 secondary label。
- 线性 `ProgressView`；只有转换中、排队、暂停和失败时显示状态文字。
- 状态由 SF Symbol + 文字共同表达，不只依赖颜色。

工具栏尾部提供系统搜索框，范围为标题和作者。筛选使用 `Menu`，不把多个胶囊按钮铺满工具栏。

空态使用 `ContentUnavailableView`：书籍图标、“尚未导入书籍”、“导入 EPUB 开始制作”，以及一个“导入 EPUB”主按钮；整个空态同时接受拖放。

### 12.4 书籍详情

顶部使用简洁详情头：封面、书名、作者、章节数、预计工作量和总进度。主要动作随状态变化：

| 状态 | 主要动作 | 次要动作 |
|---|---|---|
| ready | 开始转换 | 删除 |
| queued | 从队列移除 | — |
| converting | 暂停 | 显示队列 |
| paused/interrupted | 继续 | 取消任务 |
| completed | 导出有声书… | 在 Finder 中显示 |
| failed | 重试 | 查看错误详情 |

章节主体使用 `Table` 或带列的 `List`：序号、章节标题、状态、时长。章节行不重复放“开始/暂停/继续”，这些是书籍级任务操作；失败章节可在上下文菜单中单独重试。这样可避免每行按钮噪声和误操作。

### 12.5 模型管理

Content 列为系统 List，而非网格卡片：模型名称、框架、安装状态、默认勾选。Detail 显示模型标识、框架、运行时状态、支持语言、版本和能力。

- “设为默认”是清晰的按钮；当前默认使用 checkmark 和“默认”文字。
- 未安装模型不显示可执行的“切换”，而显示“运行时尚未提供此模型”。
- 语音参数入口以 disabled Form section 预留，并附“将在后续版本提供”，避免可点但无反应。

### 12.6 工具栏、菜单与快捷键

工具栏遵循 macOS 位置习惯：

- leading：系统 sidebar toggle、当前区域标题。
- center：最常用的“导入 EPUB”。
- trailing：上下文任务动作、搜索、队列状态。
- 破坏性和低频动作放在上下文菜单或 More menu，不常驻工具栏。

标准命令：

| 命令 | 快捷键 |
|---|---|
| 导入 EPUB… | ⌘O |
| 搜索 | ⌘F |
| 开始/继续转换 | ⌘Return |
| 暂停当前任务 | ⌘. |
| 导出有声书… | ⇧⌘E |
| 删除选中书籍 | Delete |
| 显示/隐藏侧边栏 | ⌃⌘S（使用系统命令时以系统默认值为准） |
| 设置… | ⌘, |

菜单栏至少包含 File、Edit、View、Book、Window、Help。所有可点击主要命令都应在菜单栏可发现，支持键盘工作流。

### 12.7 底部状态区

需求中的底部状态栏保留，但仅呈现补充信息，不承载唯一的关键操作：队列数、活跃数、完成数和“查看队列”。高度保持紧凑，使用系统 separator 与 secondary text，不自绘高对比背景。

HIG 建议避免把关键信息只放在窗口底部，因此当前转换进度也必须在书籍列表、详情和工具栏状态中可见。

### 12.8 Liquid Glass 与视觉规范

- 采用系统最新外观和控件默认材质，让 SwiftUI 自动获得 Liquid Glass 行为。
- 不叠加自定义 blur、透明描边、发光、渐变玻璃卡片或仿制系统材质。
- 内容层使用标准 window/list/background；工具栏和 sidebar 由系统控制材质。
- 只使用语义颜色：`primary`、`secondary`、`accentColor`、`red`（破坏性）。
- 使用系统文字样式，不固定字体字号；数字进度可使用等宽数字设计。
- 图标只用 SF Symbols；自定义产品图标遵循 macOS App Icon 模板，不把 App 图标当作界面按钮。
- 动效仅用于状态连续性，尊重 Reduce Motion；暂停、完成和失败不能依赖动画才能理解。

### 12.9 对话框与错误

- 导入错误尽量内联显示在对应文件或书籍，不为每个失败连续弹 alert。
- 删除书籍使用原生确认，明确写“不会删除原始 EPUB”。
- 可恢复错误提供主操作“重试”和次操作“显示详情”。
- 错误文本采用“发生了什么 + 用户能做什么”，不显示 Python traceback、NSError dump 或内部路径。
- 多文件导入完成后用汇总结果 sheet：成功 N、跳过 N、失败 N，可展开详情。

### 12.10 可访问性与本地化

- VoiceOver 顺序与视觉阅读顺序一致；进度读为“已完成 42%，正在转换第 8 章”。
- 状态图标提供可本地化 label，装饰图标隐藏 accessibility。
- 支持 Full Keyboard Access、系统焦点环和菜单命令。
- 不只用红/绿表达失败/完成；必须有文字或符号。
- 支持 Increase Contrast、Reduce Transparency、Reduce Motion 和深浅色模式。
- 所有文案进入 String Catalog；首版至少简体中文和英文，布局不得假设固定字符串长度。

---

## 13. 隐私、安全与沙箱

- 启用 App Sandbox，只申请 User Selected File Read/Write；内部文件保存在 App 容器。
- EPUB 内容、章节正文、模型请求和音频不进行网络上传。
- App 的网络客户端能力仅服务于用户主动发起的签名模型下载；请求只包含固定 artifact URL 与 App User-Agent，不读取或附带书名、正文、试听文本、voice 设置、音频、文件路径或其他用户内容。每份清单声明精确 HTTPS origin/redirect 主机；模型安装后可完全离线运行。
- security-scoped URL 只在复制或导出期间短时持有；导出目录书签仅在用户明确选择后保存。
- 解包防 Zip Slip、压缩炸弹、路径逃逸、符号链接与超大资源。
- XPC 接口限制允许调用的方法、输入大小和文件位置，校验服务签名和协议版本。
- OSLog 对书名、作者、文件路径使用 private privacy；永不记录章节全文。
- 删除时清理 App 管理的正文和音频；由于 APFS/SSD 特性，不承诺物理安全擦除。

---

## 14. 性能与资源策略

- 导入、哈希、XML/HTML 解析、图片解码、音频编码和 ZIP 均离开 MainActor。
- EPUB 和音频使用流式 I/O，不一次性载入整本书或整章 PCM。
- 封面缩略图使用 ImageIO downsampling，列表不解码原尺寸图片。
- SwiftData 批量写入并分阶段保存，避免为每个字符或音频帧更新数据库。
- UI 进度节流到约 4–10 次/秒；持久化进度进一步降低频率，只在 checkpoint 和显著变化时保存。
- 使用 OSLog signpost 测量 import、parseChapter、synthesize、package、export；不采集正文。
- App 进入后台或系统热压力升高时不增加新并发；运行时能力允许时降低并发。

---

## 15. 错误模型

统一错误类型按领域分类：

```text
ImportError
  unsupportedEPUB · encryptedEPUB · invalidContainer · unsafeArchive
  missingPackage · noReadableChapters · invalidCover

RuntimeError
  unavailable · incompatibleVersion · modelMissing · modelLoadFailed
  requestRejected · cancelled · timeout · invalidAudio

PackagingError
  audioEncodeFailed · metadataWriteFailed · textTrackUnsupported
  verificationFailed · insufficientDiskSpace

ExportError
  destinationUnavailable · archiveWriteFailed · cancelled
```

每个错误包含稳定 code、本地化用户说明、恢复建议和可选底层 cause。正文与绝对路径不得进入遥测字段。

---

## 16. 测试与验收

### 16.1 单元测试

- EPUB：EPUB 2/3、NAV/NCX、空章节、缺封面、异常路径、压缩炸弹阈值、中文/RTL/emoji 标题。
- 纯文本：段落、实体、Ruby、隐藏内容、Unicode 规范化和超长章节。
- 状态机：所有合法迁移、非法迁移拒绝、暂停竞态、失败重试和异常退出恢复。
- 调度：FIFO、并发 1/2、运行时上限、取消传播、模型锁定。
- 文件：原子提交、同名清理、删除与撤销、磁盘空间不足。
- M4B 导出：多章时间轴、章节顺序、封面、作者/旁白者/类型/日期元数据、取消和原子提交。

### 16.2 集成测试

- 使用确定性 `MockTTSRuntimeClient` 生成短 PCM，完整跑通 EPUB → 分章 M4B → 单文件 M4B。
- 最终 M4B 用 AVURLAsset 回读单一音频轨、所有章节项、文本轨、封面、元数据和时长。
- App 运行到任意 checkpoint 后模拟终止，重启验证不重复已完成章节。
- XPC invalidation、timeout、cancel 和模型版本不兼容。

### 16.3 UI 测试

- 导入、拖放、搜索、筛选、开始、暂停、继续、删除、导出。
- 窗口最小尺寸、全屏、列折叠、深浅模式。
- VoiceOver label、Full Keyboard Access 和所有快捷键。
- Reduce Motion、Increase Contrast、长英文/中文文案。

### 16.4 发布验收门槛

- 主线程无文件 I/O、解压、媒体编码或同步 XPC 调用。
- 任一受控中断点重启后都能恢复，完成章节不重做。
- 删除书籍不会触碰用户原始 EPUB。
- M4B 在 Apple Books/QuickTime Player 可播放，AVFoundation 可读到规定轨道与元数据。
- 最终导出只有一个 `.m4b` 文件，章节顺序、封面和元数据均可被 AVFoundation 回读。
- 无第三方运行库进入 App 主体 target；若推理运行时包含非 Apple 组件，必须单独披露和签名。

---

## 17. 里程碑与技术预研

### Spike 0：先消除高风险

1. 用 Foundation + Compression 完成最小 ZIP reader/writer，验证常见 EPUB 和 Finder 解压兼容性。
2. 用 AVFoundation 生成 30 秒 M4B，验证封面、t=0 章节项和整章 text track。
3. 用 mock XPC service 验证大音频文件传递、取消、超时和 App Sandbox。
4. 验证 Swift 6 严格并发与 SwiftData ModelActor 的后台写入模式。

任何一项失败都应在开始完整 UI 前回到设计评审。

### M1：原生骨架

- Swift 6、SwiftData schema、依赖容器。
- 三栏 UI、菜单、Settings、空态和 Preview 数据。
- Queue/Chapter 状态机与 mock runtime。

### M2：导入与解析

- 文件选择、拖放、App 容器复制、安全 ZIP 解包。
- OPF/NAV/NCX、纯文本和封面。
- 书籍列表、详情与导入错误汇总。

### M3：模型与运行时契约

- 模型列表、默认模型、能力展示。
- XPC DTO、握手、状态、取消和 mock/real transport 切换。
- Kokoro 下载、音色试听、真实 sherpa-onnx 合成与双架构验收。

### M4：任务与恢复

- actor 队列、并发策略、进度、暂停继续。
- checkpoint、异常退出恢复、失败重试。

### M5：媒体与导出

- AAC/M4B、章节、封面、文本轨。
- 单文件 M4B 合并导出、Finder 展示与媒体回读验证。

### M6：HIG 与质量

- 可访问性、键盘、菜单、本地化、深浅模式和窗口适配。
- 性能 signpost、安全测试、App Sandbox、签名与发布验收。

---

## 18. 需求追踪矩阵

| 需求 | 设计落点 |
|---|---|
| FR-1.1～1.3 | §7 EPUB 导入、解析、封面 |
| FR-1.4～1.6 | §12 书籍列表与详情 |
| FR-1.7～1.8 | §9 队列、并发、断点恢复 |
| FR-1.9 | §1.1、§6、§13 删除策略 |
| FR-2.1～2.5 | §8、§12.5 模型协议与界面 |
| FR-3.1～3.4 | §10 M4B 封装 |
| FR-3.5～3.6 | §11 单文件 M4B 导出 |
| 多框架适配 | §8.3 capability-driven adapter |
| SwiftData | §5 数据设计 |
| 隐私/性能/扩展性 | §13、§14、§4 |

---

## 19. Apple 设计与开发依据

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)
- [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/)
- [SwiftData ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)
- [AVMutableMovie](https://developer.apple.com/documentation/avfoundation/avmutablemovie)
- [AVAssetWriter metadata](https://developer.apple.com/documentation/avfoundation/avassetwriter/metadata)
- [Compression](https://developer.apple.com/documentation/compression)
- [Process and App Sandbox](https://developer.apple.com/documentation/foundation/process)

---

## 20. 实现前仍需确认

1. 发布渠道是 Mac App Store、Developer ID 直接分发，还是两者都支持；这会影响 XPC/运行时打包和审核策略。
2. 第三方 TTS 推理层采用 sherpa-onnx/ONNX Runtime CPU 后端；其余应用层继续使用 SwiftUI、SwiftData、AVFoundation、URLSession、CryptoKit 与 App Sandbox。
3. M4B 文本轨在目标播放器中的最低兼容范围；设计以 Apple Books、QuickTime Player 和 AVFoundation 为优先验收对象。
4. 最大可接受 EPUB 体积、章节长度和磁盘占用，用于冻结安全阈值与空间预检策略。
