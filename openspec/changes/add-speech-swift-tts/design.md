## Context

AudiobookMaker 当前通过 `RoutingTTSRuntimeClient` 在 Apple 系统语音与 sherpa-onnx Kokoro 之间路由；`ModelPackageManager` 负责签名清单、用户触发下载、校验、原子安装和恢复，模型页面已提供安装、音色选择与试听。持久化任务锁定 model ID、model version 和 voice ID，因此新增运行时不能绕过这些边界。

speech-swift 提供独立的 `CosyVoiceTTS` 与 `Qwen3TTS` Swift Package 产品，基于 MLX/CoreML 在 Apple Silicon 本地运行。当前官方要求 Swift 6、Xcode 16、macOS 15+ 和 Apple Silicon；MLX 路径还要求正确打包 Metal shader library。CosyVoice3 输出 24 kHz 音频并支持 9 种语言，Qwen3-TTS 输出 24 kHz 音频且存在严格的 token/KV-cache 与 GPU watchdog 风险。模型包约为 GB 级，不能进入 App bundle，也不能由库在合成时隐式联网。

## Goals / Non-Goals

**Goals:**

- 在原生 Apple Silicon 环境提供 CosyVoice3 与 Qwen3-TTS，并保持 Intel/Rosetta 上的现有功能不变。
- 复用 Kokoro 的模型详情、下载、音色、试听、默认模型和转换交互。
- 通过统一运行时协议确保队列锁定、暂停恢复、音频校验、隐私和错误行为与底层框架无关。
- 固定依赖和模型版本，支持完整离线合成、可复现构建及许可证/SBOM 审计。
- 对高内存模型实施串行推理、文本上限和实机发布门禁。

**Non-Goals:**

- 不提供麦克风录音、参考音频导入、零样本音色克隆、多说话人对话、情绪标签或自由风格指令。
- 不在 Intel Mac、Rosetta 进程或不满足 speech-swift 最低系统条件的设备上运行 MLX 模型。
- 不替换 Kokoro、Apple 系统语音或现有 M4B 封装流程。
- 不允许 speech-swift 在合成时自行联网，也不提供云端推理回退。

## Decisions

### 1. 使用编译期依赖加运行期平台门禁

固定 speech-swift 的已验证 release tag 和解析后的 revision，只链接 `CosyVoiceTTS`、`Qwen3TTS`、`AudioCommon` 及其必要传递依赖。通过一个可注入的 `SpeechSwiftPlatformSupport` 同时检查进程架构、Rosetta 翻译状态、系统版本与 Metal 可用性；只有全部满足时才将两个模型发布到目录并构造运行时。

选择运行期门禁而不是单独维护 arm64 App，是为了继续发布现有 universal App。不能只检查硬件型号，因为 Apple Silicon 上以 Rosetta 启动的 x86_64 进程同样不能加载 arm64/MLX 依赖；测试必须覆盖该差异。

### 2. 在现有路由器后增加隔离的 speech-swift 适配器

新增 `SpeechSwiftTTSRuntimeClient` actor，内部按 model ID 延迟创建并缓存 CosyVoice3 或 Qwen3-TTS session。`RoutingTTSRuntimeClient` 仍是业务层唯一入口；它根据稳定 model ID 路由到 system、Kokoro 或 speech-swift 适配器。适配器负责把库返回的 Float PCM/WAV 转换为受控目录中的 CAF/PCM，并复用现有 `SynthesisResult` 音频校验。

模型首次加载和合成在非主 actor 的串行执行上下文完成；每个模型的 `recommendedConcurrency` 初始为 1。取消使用 Swift task cancellation，并在上游库不能中止当前 Metal kernel 时报告“完成当前安全边界后取消”，不得把晚到结果提交给已取消请求。

选择进程内 actor 而不是立即新增 XPC 服务，是因为 speech-swift 是原生 Swift/MLX 包，当前工程没有独立 speech service target；actor 能以较小改动接入统一协议。若实机验证发现 Metal 崩溃会影响主进程，再将相同适配器移动到签名 XPC target，业务契约无需变化。

### 3. 模型包仍由 App 管理，不使用合成时隐式下载

把 `TTSModelCatalog.kokoro` 单例演进为按 ID 索引的签名 manifest 集合。每份清单包含平台约束、模型/变体 ID、speech-swift runtime revision、下载与展开大小、SHA-256、许可、必需路径和允许的重定向来源。下载器只接受每份清单声明的 HTTPS origin/redirect host，并把所有模型安装到 `Application Support/.../Models/<encoded-id>/<version>`。

speech-swift session 必须从已验证的本地 URL 初始化；任何 `fromPretrained()` 的默认联网行为都通过显式本地路径或注入下载器关闭。安装器去除当前硬编码的 Kokoro package root，改为由 manifest 声明 archive root/布局。活动下载、resume data、进度与取消状态按 model ID 隔离，允许目录展示多个模型但同一时间只执行一个大包下载。

这比直接调用 speech-swift/Hugging Face 下载器多一些清单维护成本，但保留了现有的用户同意、哈希验证、路径安全、离线保证和审计能力。

### 4. 初始模型变体以有声书稳定性和可选音色为准

CosyVoice3 固定官方支持的 Fun-CosyVoice3-0.5B 3.0 系列量化变体；Qwen3-TTS 固定一个经过验收的 0.6B/1.7B 变体。最终 manifest 在实现 spike 中以磁盘、峰值内存、中文质量、可恢复性和许可证结果确定，且稳定 model ID 必须包含模型族与变体，升级不得覆盖旧任务引用的版本。

首版只把库能够稳定复现且无需用户录音的 speaker/voice 暴露为 `TTSVoiceDescriptor`。若某个 Base 变体只有一个默认 speaker，目录仍提供一个稳定的 `default` voice ID；不会假装提供克隆音色。Qwen3 CustomVoice 只有在可合法分发、可离线安装且预置 speaker 通过验收后才列入 manifest。

### 5. 长文本按运行时预算切片并保持任务选择不变

`RuntimeCapabilities` 增加平台支持状态、估算内存等级和运行时特定文本/token 预算。业务层继续按字符切章，但 speech-swift 适配器会在句子边界执行第二层安全切片：Qwen3-TTS 必须低于运行时最大 token/KV-cache 限制，默认不超过官方建议的约 40 秒单次生成；CosyVoice3 按实测稳定上限切分。片段按顺序写入并验证 24 kHz 单声道音频，再交给现有章节合并流程。

任务创建时继续锁定 model ID/version/voice ID。更新或删除模型时，安装器不得清理任何未完成任务引用的版本；恢复时平台或模型不可用则保持暂停，不得回退到 Kokoro 或其他音色。

### 6. UI 复用能力驱动的模型详情

模型列表由 manifest、持久化安装状态和 `SpeechSwiftPlatformSupport` 合并生成。兼容的 Apple Silicon 显示 CosyVoice3/Qwen3-TTS 与 Kokoro 相同的下载、进度、修复、默认模型、音色搜索和试听控件；不兼容设备隐藏下载操作，并以“需要 Apple Silicon”解释不可用原因。快捷菜单、设置 Picker、旁白元数据和可访问性标签都从同一目录生成，不再硬编码 Kokoro。

模型切换仍只影响新任务。试听与正式转换共享运行时并发配额，新试听抢占旧试听，但不得抢占正在执行的正式片段。

### 7. 供应链与发布门禁

依赖必须固定 tag/revision，记录 speech-swift、MLX Swift、模型权重与 tokenizer/codec 的许可证、Notice、来源哈希和 SBOM。Release 构建检查 App bundle 不含任何模型权重，但包含所需的 Metal library；签名、公证和沙箱启动后再执行离线合成。

Apple Silicon 实机验收分别覆盖两个模型的下载、冷/热加载、固定试听样句、中文 EPUB、暂停/取消、长章节、峰值内存、RTF 和清理。另以 Intel 原生进程与 Apple Silicon Rosetta 进程验证模型不可见、无下载且不加载 MLX。自动测试不得替代中文听感验收。

## Risks / Trade-offs

- [speech-swift API 和模型仓库变化快] → 固定 release/revision 与模型 manifest，升级作为独立变更并运行兼容性测试。
- [GB 级模型下载和磁盘占用] → 下载前展示精确大小与可用空间，按模型管理版本、断点和安全清理，禁止自动下载。
- [MLX Metal kernel 导致高内存、系统卡顿或 watchdog] → 并发固定为 1、限制单片 token/时长、预热后记录峰值内存，超出发布阈值时禁用对应变体。
- [上游取消不是即时的] → 采用协作式取消并丢弃晚到结果，UI 显示“完成当前片段后暂停”，不声称立即终止 GPU kernel。
- [CosyVoice3/Qwen3-TTS 的音色模型与 Kokoro 不同] → UI 复用交互而非伪造相同语义；只展示稳定预置 speaker，克隆与风格功能延后。
- [进程内推理崩溃影响 App] → 先用 actor 隔离资源和状态；若实机故障注入不能满足恢复门禁，则在发布前转为 XPC 服务。
- [Hugging Face 重定向域名变化] → manifest 明确允许的 origin/redirect 集合，变化时通过签名清单/App 更新处理，不放宽为任意主机。

## Migration Plan

1. 先加入固定依赖、许可证和可重复构建 spike，不向用户发布模型目录项。
2. 扩展 manifest、安装状态和持久化迁移；旧 Kokoro/system 记录保持原 ID 与默认值。
3. 加入 speech-swift 适配器和路由，在开发开关下完成本地模型与音频验证。
4. 启用 Apple Silicon 条件目录和 Kokoro 风格 UI，运行数据迁移、队列恢复与离线测试。
5. 完成实机性能、听感、签名、公证与 Rosetta/Intel 负向门禁后移除开发开关。

回滚时从目录隐藏两个 speech-swift model ID 并阻止新任务，保留已安装文件和历史任务选择供诊断；已锁定但无法运行的任务保持暂停并提示安装兼容版本，不自动改用其他模型。后续版本确认无未完成任务引用后才允许用户清理旧模型。

## Open Questions

- 实现 spike 后在 Qwen3-TTS 0.6B CustomVoice、1.7B 8-bit 与 CoreML 变体中选择哪一个作为首发，取决于中文听感、峰值内存、磁盘和预置 speaker 授权结果。
- speech-swift 的取消/资源释放能否满足主进程故障隔离门禁；若不能，首发实现将切换为独立签名 XPC 服务。
- CosyVoice3 首发是否只提供 default voice，还是可以随 App 提供经授权、体积受控的参考音频/embedding；在授权确认前不得打包参考声音。
