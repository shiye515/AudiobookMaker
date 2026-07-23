## Context

当前应用以 Universal 2 形式发布，并同时包含两条本地 AI TTS 路径：Kokoro 依赖随包分发的 `SherpaOnnx.xcframework` 与 `OnnxRuntime.xcframework`，可在 Intel/Apple 芯片上使用；CosyVoice3 和 Qwen3-TTS 依赖本地 `speech-swift`、MLX Swift 与 Metal，仅支持原生 Apple Silicon。模型目录、安装器、运行时工厂、UI、验收入口、许可/SBOM 和发布文档因此都维护双运行时及 Intel/Rosetta 降级分支。

本变更是破坏性平台收敛。目标用户是运行受支持 macOS 的 Apple Silicon Mac 用户；升级用户可能保留 Kokoro 默认设置、已安装模型目录和绑定 Kokoro 的未完成任务。应用仍须维持本地处理、显式模型下载、可恢复队列、原子安装和标准 M4B 输出等既有契约。

## Goals / Non-Goals

**Goals:**

- 只构建、测试、签名、公证和发布原生 arm64 应用及其可执行依赖。
- 完整移除 Kokoro、sherpa-onnx、ONNX Runtime 和仅服务于 Intel/Rosetta 降级的代码、资源与维护面。
- 将 AI TTS 路径统一到 speech-swift/MLX/Metal，并保留 Apple 系统语音作为低资源、无需下载的后端。
- 为旧 Kokoro 设置、模型安装和未完成任务提供确定、幂等且不会混合音频的迁移。
- 建立同机可重复的性能与产物门禁，使 Apple 芯片专项优化可持续验证，而不是依赖主观感受。

**Non-Goals:**

- 不继续提供 Intel、Rosetta、Universal 2 或独立兼容版本。
- 不把 Kokoro 移植到 Core ML、MLX 或其他 Apple 专用运行时。
- 不在本变更中新增 TTS 模型、声音克隆能力或云端推理。
- 不改变 EPUB 解析、M4B 封装格式、书库隐私边界或现有模型供应链信任模型。
- 不承诺跨不同芯片代际的绝对耗时；性能验收使用固定设备、固定模型与固定语料的同机基线。

## Decisions

### 1. 在构建与发布边界实施 arm64-only

应用及测试 target 显式限定 `ARCHS = arm64`，Release/Archive 禁止生成 x86_64 slice。发布验证使用 Mach-O 架构检查覆盖主可执行文件、嵌入 framework、dylib 和辅助可执行文件，并在签名、公证前失败关闭。

选择编译期/产物期约束，而不是保留 Universal 2 后在运行时隐藏功能：前者能真实移除代码和依赖 slice、缩小测试矩阵，也避免 Rosetta 进程误入 MLX。备选方案“继续 Universal 2，仅下线 Kokoro”仍需维护 Intel 上无 AI 模型的降级产品，不能达到维护与性能收敛目标。

### 2. TTS 后端收敛为 Apple Speech + speech-swift/MLX

模型目录只包含 Apple 系统语音、CosyVoice3 和 Qwen3-TTS。删除 Kokoro manifest、voice catalog、runtime client、acceptance runner、菜单/详情分支，以及工程中 Sherpa/ONNX framework 的链接和嵌入项。保留统一 `TTSRuntimeClient` 领域边界，但其具体实现仅覆盖 AVFoundation 与 speech-swift，业务队列仍不直接依赖模型框架。

选择删除而非 feature flag：feature flag 会保留二进制依赖、死代码和持续测试义务。平台探测仍检查最低 macOS、原生 arm64、Metal 与运行时健康，但不再向用户呈现 Intel/Rosetta 功能降级路径；架构不兼容由系统安装/启动边界和发布验证共同阻止。

### 3. 迁移以“安全重置”代替跨模型续跑

启动迁移按 schema/version 标记执行且幂等：

1. 默认模型或最近音色引用 Kokoro时，改为 Apple 系统语音并清除 Kokoro voice ID。
2. Kokoro 的安装记录、resume data 和下载状态从模型仓库移除；仅删除已验证位于 App 管理模型根目录内的 Kokoro 目录，路径异常时记录并跳过。
3. 绑定 Kokoro 的排队、暂停、中断或转换中任务保留书籍与任务元数据，但标记为“模型已移除，需要重新开始”；不得把已有 Kokoro checkpoint 交给其他后端继续。
4. 用户重新开始该任务时，通过既有重置流程清理旧 checkpoint，再用当前选择的受支持模型创建新任务快照。已完成并已导出的音频不受影响。

备选方案“自动改用 MLX 模型续跑”会造成同一 M4B 的音色、韵律和采样特征不一致，因此拒绝采用。自动无条件删除所有旧目录也有路径误删风险，故只清理经规范化与根目录校验的托管资源。

### 4. Apple Silicon 优化围绕可测量的统一路径进行

不引入第二套优化抽象。基于现有 speech-swift 能力协商统一执行：模型会话在同一模型的连续片段间复用；切换模型、内存压力或不可恢复错误时释放；并发保持运行时声明与安全上限的较小值；文本在 token、KV-cache 和安全生成时长预算前切片；取消停止后续提交并丢弃晚到结果。Apple 系统语音继续使用独立轻量后端。

性能基线固定设备型号/内存、系统与构建配置、模型 revision、语料、冷启动/热启动定义和采样方法，记录应用体积、模型加载时间、首段首音频时间、稳态合成吞吐、峰值常驻内存及失败率。Release 与最近批准的 Apple Silicon 基线比较：关键指标不得发生超出门限的回归；任何门限调整必须连同原因和新基线审查。

选择“基线 + 回归门限”而不是写死跨设备绝对数字，因为 MLX/Metal 性能随芯片、系统和模型 revision 变化；固定实验条件仍能捕获代码与打包回归。

### 5. 依赖纯净性是发布契约

工程文件、Copy/Embed phases、运行时搜索路径、源码、测试夹具、文档和 SBOM 中移除 Sherpa/ONNX/Kokoro 发行内容。发布检查同时扫描链接依赖和 App bundle 内容，不能只依赖源码搜索。speech-swift 与 MLX 的版本仍由模型 manifest/工程锁定，并继续执行离线加载、哈希、签名和许可校验。

## Risks / Trade-offs

- [Intel 用户无法使用新版本] → 将版本标记为破坏性升级，在 Release 页面保留最后一个 Universal 2 版本及明确支持边界，但不继续维护双线功能。
- [删除 Kokoro 减少可选音色并失去较小 CPU 模型] → 保留 Apple 系统语音作为无需下载的低资源选项，并清晰展示 CosyVoice3/Qwen3-TTS 的大小和资源要求。
- [旧任务迁移导致需要重新生成] → 保留书籍/任务元数据，明确解释模型已移除；禁止静默续跑以优先保证音频一致性。
- [托管 Kokoro 文件清理误删] → 仅允许在规范化后的模型根目录内按已知 model ID/version 删除，异常路径失败关闭并记录。
- [MLX/Metal 成为单一 AI 运行时故障域] → Apple 系统语音保持可用；继续运行时健康检查、稳定领域错误和 checkpoint 恢复。
- [“极致优化”演变为不可复现的局部微调] → 先固化基准语料、设备和指标，所有优化以 profile 和同机门禁数据证明。
- [移除 framework 后工程引用残留造成归档失败] → 同时验证工程引用、链接图、bundle 内容、代码测试和签名归档，不以 Debug 编译通过作为完成标准。

## Migration Plan

1. 先加入迁移测试、arm64 产物检查和 Apple Silicon 性能基准，记录变更前基线。
2. 从领域目录和 UI 移除 Kokoro，再删除运行时实现、验收入口和专属测试；保持每一步可编译。
3. 删除 Sherpa/ONNX 工程链接、嵌入项和 vendor 二进制，切换所有 target/CI/Archive 到 arm64-only。
4. 实现并验证旧默认值、安装状态、resume data 与未完成任务迁移，包括重复启动幂等性和路径安全。
5. 更新许可、SBOM、README、开发/发布文档和 Release notes；在干净 Apple Silicon 环境执行下载、离线试听、转换、恢复、导出与公证验收。
6. 比较体积、加载、首音频、吞吐和峰值内存基线，处理超门限回归后发布。

回滚仅能回到最后一个 Universal 2 版本；新版本迁移不得破坏书库或已导出文件。由于旧版本仍认识 Kokoro ID，迁移使用可忽略的版本标记并保留核心书籍数据格式；但已由新版本清理的 Kokoro 模型权重需要用户在旧版本重新下载。

## Open Questions

- 发布时是否提高 major version，以向 Intel 与 Kokoro 用户明确表达不兼容升级？
- 最后一个 Universal 2 安装包保留多久、是否仅提供安全修复，需要在发布策略中确认。
- 首个性能门禁的固定 Apple Silicon 设备型号、基准语料及各指标允许回归百分比，需要由维护者在采集变更前基线后批准。