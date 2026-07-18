## 1. 工程基线与高风险预研

- [x] 1.1 为现有模板记录可构建基线，新增 Swift Testing、XCTest/XCUITest target 和测试 fixture 目录
- [x] 1.2 将工程迁移到 Swift 6 严格并发与 macOS 26+，清零现有并发诊断
- [x] 1.3 配置 App Sandbox、User Selected File Read/Write、`UTType.epub` 文档类型和简中/英文 String Catalog
- [x] 1.4 用 Foundation FileHandle + Compression 完成最小 ZIP reader/writer spike，并验证 EPUB 2/3、Store、Deflate、UTF-8 文件名和 Finder 解压
- [x] 1.5 用 AVFoundation 生成 30 秒 M4B spike，并验证音频、封面、t=0 章节项和独立整章文本轨可被 AVURLAsset 回读
- [x] 1.6 使用 Apple Books 和 QuickTime Player 人工验证 M4B spike，记录可接受参数或阻断项
- [x] 1.7 用 mock XPC service 验证版本握手、临时音频文件传递、幂等取消、连接失效和沙箱路径限制
- [x] 1.8 验证 SwiftData ModelActor 后台批量写入与 Swift 6 Sendable 边界，形成可复用持久化模式

## 2. 分层架构与领域模型

- [x] 2.1 建立 App、Features、Application、Domain、Infrastructure 和 Resources 目录与 target membership
- [x] 2.2 实现依赖容器，注入持久化、文件存储、EPUB、运行时、媒体、归档和日志协议
- [x] 2.3 定义 BookStatus、ChapterStatus、JobState 及其合法状态迁移和领域错误
- [x] 2.4 定义 Sendable 的 Book/Chapter/Queue/Runtime 展示快照，禁止跨 actor 传 SwiftData 模型对象
- [x] 2.5 为状态机的所有合法与非法迁移添加 Swift Testing 测试

## 3. SwiftData 与文件存储

- [x] 3.1 用 Book、Chapter、TTSModel、ConversionJob 和 AppSetting 替换示例 Item schema
- [x] 3.2 配置 Book-Chapter 与 Book-Job 关系、唯一约束、级联删除和默认设置种子
- [x] 3.3 实现 ModelActor repository，提供书籍、章节、模型、任务和 checkpoint 的事务方法
- [x] 3.4 实现 Application Support/Caches 目录解析器，仅在数据库保存相对路径
- [x] 3.5 实现书籍 staging、原子提交、`.partial`、App 内 Trash 和当前会话撤销清理流程
- [x] 3.6 实现 SHA-256 文件/文本哈希、Finder 可见文件名清理和磁盘空间预检
- [x] 3.7 添加 repository、原子提交、崩溃残留清理、级联删除和“原始 EPUB 不受影响”测试

## 4. 原生 macOS 应用骨架

- [x] 4.1 用三栏 NavigationSplitView 替换模板 ContentView，建立书籍/模型 Sidebar 和自适应列宽
- [x] 4.2 实现书籍 List、封面缩略图、状态、ProgressView、搜索、筛选和系统空态
- [x] 4.3 实现书籍 Detail header、章节 Table、状态相关主要动作和失败章节上下文菜单
- [x] 4.4 实现模型 List 与 Detail，展示框架、安装/加载状态、能力和默认标记
- [x] 4.5 实现紧凑底部队列状态区，并确保关键进度同时出现在列表、详情和工具栏
- [x] 4.6 实现标准 File/Edit/View/Book/Window/Help 命令、工具栏和设计规定的键盘快捷键
- [x] 4.7 实现 Settings Scene，提供并发 1/2、默认模型和中间 PCM 保留设置
- [x] 4.8 添加 Preview/mock 数据，使宽窗口、窄窗口、空态、转换、暂停、完成和失败界面可独立预览

## 5. 安全 EPUB 解包

- [x] 5.1 将 ZIP spike 整理为流式 ZipContainerReader，解析 EOCD、中央目录、本地头、Store 和 Deflate
- [x] 5.2 实现 CRC 校验、路径规范化和绝对路径、父目录逃逸、符号链接、加密条目、多磁盘及未知方法拒绝
- [x] 5.3 实现可配置的文件数、单文件大小、总展开大小和压缩比安全上限
- [x] 5.4 实现 ZipContainerWriter 的 Store/Deflate、UTF-8 文件名、CRC 和所需 ZIP64 子集
- [x] 5.5 添加正常 EPUB、异常 CRC、Zip Slip、压缩炸弹阈值、加密与不支持格式测试语料和单元测试

## 6. EPUB 导入与资料库管理

- [x] 6.1 实现 `fileImporter` 多选 EPUB 与书籍区域 `dropDestination`，正确成对管理 security-scoped 访问
- [x] 6.2 实现 ImportCoordinator 的复制、类型/可读性检查、哈希、staging 和逐文件结果汇总
- [x] 6.3 使用 XMLParser 实现 container.xml、OPF metadata/manifest/spine、EPUB 3 NAV 和 EPUB 2 NCX 解析
- [x] 6.4 使用 Foundation `XMLParser` 的受控 XHTML 正文抽取实现段落/空白归一化、Unicode NFC、空章节跳过和缺失标题回退（避免 HTML importer 的 AppKit 布局副作用）
- [x] 6.5 使用 ImageIO 实现封面发现、格式校验、App 内保存和列表降采样缩略图
- [x] 6.6 实现重复 SHA-256 导入确认，支持定位已有书籍或显式创建副本
- [x] 6.7 实现书籍删除确认、App 管理数据清理、当前会话撤销和原始 EPUB 保护
- [x] 6.8 添加 EPUB 2/3、NAV/NCX、缺元数据、缺封面、空章节、中文/RTL/emoji 和事务失败集成测试

## 7. TTS 模型与运行时契约

- [x] 7.1 定义 TTSRuntimeClient、RuntimeCapabilities、SynthesisRequest/Result 和稳定 RuntimeError
- [x] 7.2 实现确定性 MockTTSRuntimeClient，可生成短 PCM、模拟延迟、进度、取消、超时和错误
- [x] 7.3 实现 CosyVoice3 0.5B 目录种子、模型列表同步、唯一默认模型和任务模型锁定
- [x] 7.4 实现 NSXPCConnection DTO、NSSecureCoding、健康/版本/能力握手和服务身份校验
- [x] 7.5 实现模型加载、文件型音频结果传递、允许路径校验、幂等取消、超时和 invalidation 处理
- [x] 7.6 实现按运行时最大文本长度切片并按原顺序合并的纯领域算法
- [x] 7.7 添加兼容/不兼容握手、默认模型切换、长文本切片、重复取消、容器外路径和无效音频测试

## 8. 转换队列与断点恢复

- [x] 8.1 实现 ConversionCoordinator actor、持久化 FIFO queueOrdinal 和活跃任务表
- [x] 8.2 实现默认并发 1、用户上限 1/2 与 runtime recommendedConcurrency 的联合限制
- [x] 8.3 实现同书章节顺序执行、任务模型固定和片段/章节/任务 checkpoint
- [x] 8.4 实现基于完成字符数的 QueueSnapshot 进度，并节流 UI 和数据库更新
- [x] 8.5 实现 pausing/paused/continue 流程，分别处理运行时可即时取消和需完成当前片段两种能力
- [x] 8.6 实现瞬时错误最多两次指数退避，以及模型/数据/校验错误立即失败
- [x] 8.7 实现 RecoveryCoordinator，将瞬时状态恢复为 interrupted，校验 partial/最终产物并等待用户显式继续
- [x] 8.8 添加 FIFO、并发 1/2、进度权重、暂停竞态、重试上限和每个 checkpoint 模拟终止的测试

## 9. M4B 音频封装

- [x] 9.1 将媒体 spike 整理为 M4BPackager，流式读取 PCM/WAV 并用 AVAudioConverter 统一格式
- [x] 9.2 使用 AVAssetWriter 写 AAC-LC MPEG-4 Audio，冻结经 spike 验证的采样率、声道和码率
- [x] 9.3 写入章节标题、书名、作者、章节序号、语言、封面和其他可用通用元数据
- [x] 9.4 写入 t=0 章节项并与主音频轨建立 chapter association
- [x] 9.5 写入从 0 覆盖至音频结束、正文哈希匹配的单样本独立文本轨
- [x] 9.6 实现 AVURLAsset 回读验证器，检查文件、音频可播放性、时长、元数据、章节项和文本轨
- [x] 9.7 实现 `.partial` 写入、验证后原子改名和失败清理，验证成功后才提交 Chapter completed
- [x] 9.8 添加短/长章节、缺封面、编码失败、轨道缺失、校验失败和数据库提交前终止集成测试

## 10. 整书 ZIP 导出

- [x] 10.1 定义版本化 ExportMetadata schema，包含书籍信息、章节顺序、文件名、时长、模型和哈希
- [x] 10.2 实现 ExportCoordinator，按序号生成安全 M4B 文件名并加入封面、metadata.json 和 UTF-8 README.txt
- [x] 10.3 实现原生保存面板/fileExporter、同名覆盖确认、确定进度和取消
- [x] 10.4 在目标目录写隐藏临时 ZIP，校验中央目录后原子提交，失败或取消时清理且不覆盖既有文件
- [x] 10.5 添加已完成/未完成书籍、Unicode 文件名、取消、磁盘不足和 Finder Archive Utility 解压测试

## 11. 隐私、安全、错误与可观测性

- [x] 11.1 建立 ImportError、RuntimeError、PackagingError 和 ExportError 的稳定 code、本地化说明与恢复建议
- [x] 11.2 审计所有文件入口、XPC 输入和相对路径解析，确保只能访问用户授权位置或 App 容器
- [x] 11.3 使用 OSLog privacy 标记和 signpost，记录阶段、稳定 ID、耗时和错误码但不记录正文或公开绝对路径
- [x] 11.4 验证 App 在无网络条件下可完成 mock EPUB 到 ZIP 的完整流程，并确认正文和音频无网络出口
- [x] 11.5 添加恶意 EPUB、XPC 非法响应、日志脱敏、导出权限失效和磁盘空间不足安全测试

## 12. 可访问性、本地化与发布验收

- [x] 12.1 为交互控件、状态图标、进度和章节行补齐 VoiceOver label/value/hint 与合理焦点顺序
- [x] 12.2 验证 Full Keyboard Access、全部菜单快捷键、系统焦点环和仅键盘完成核心流程
- [x] 12.3 完成简体中文和英文文案，验证长字符串、未知作者、错误文本和复数状态布局
- [x] 12.4 验证深浅模式、Increase Contrast、Reduce Transparency、Reduce Motion 和窗口列折叠
- [x] 12.5 使用确定性 mock 完成 EPUB → 章节 → 队列 → M4B → ZIP 的端到端 UI 测试
- [x] 12.6 使用 Instruments/OSLog 验证主线程无解压、XML、图片解码、音频编码、ZIP 或同步 XPC 工作
- [x] 12.7 使用真实 EPUB 样本完成大文件内存、恢复一致性、Apple Books/QuickTime 播放和 Finder 解压验收
- [x] 12.8 审计 App 主体 target 不含第三方运行库，并记录推理运行时的分发、签名和许可待办
