## Why

当前 Universal 2 版本同时维护 Intel/ONNX CPU 与 Apple Silicon/MLX Metal 两套平台和推理路径，增加了二进制体积、测试矩阵、条件分支与维护成本，也限制了针对 Apple 芯片统一调优的空间。项目需要建立 Apple Silicon 专用版本，集中资源优化原生 arm64、Metal 与统一内存架构下的本地有声书生成体验。

## What Changes

- **BREAKING**：应用发行目标改为仅支持原生 Apple Silicon（arm64）；不再构建或发布 x86_64/Universal 2 版本，也不支持 Intel Mac 或 Rosetta 进程。
- **BREAKING**：移除 Kokoro 模型、sherpa-onnx/ONNX Runtime 后端及其下载、安装、音色、试听、合成、验收和许可展示能力。
- 保留 Apple 系统语音，并将 CosyVoice3 与 Qwen3-TTS 作为可下载的本地 AI 模型，通过 speech-swift、MLX Swift 和 Metal 在 Apple Silicon 上运行。
- 删除仅为跨架构兼容而存在的平台降级、Intel/Rosetta 分支、资源与测试夹具；不兼容架构在安装/启动边界即被拒绝，而不是进入功能降级模式。
- 将构建、签名、公证、发布产物、依赖打包和 CI 验证统一为 arm64，并确保不再链接或分发已移除的 ONNX 运行时组件。
- 面向 Apple 芯片统一推理路径优化模型加载、请求切片、并发和内存压力策略，同时保留可取消、可恢复、离线运行及输出校验等现有安全契约。
- 升级时若默认模型或未完成任务引用 Kokoro/已移除运行时，迁移到 Apple 系统语音并明确标记受影响任务需要重新开始，且不得静默混用不同模型继续生成。
- 更新应用内文案、README、系统要求、第三方声明、SBOM 与发布说明，明确 Apple Silicon 专用定位及 Kokoro 移除事项。

## Capabilities

### New Capabilities
- `apple-silicon-distribution`: 定义 arm64-only 构建、运行平台门槛、依赖纯净性、发布验证和 Apple Silicon 性能基线。

### Modified Capabilities
- `tts-model-installation`: 从可下载模型目录与供应链中移除 Kokoro/sherpa-onnx，只允许在原生 Apple Silicon 上安装和离线使用受信的 speech-swift/MLX 模型。
- `tts-model-runtime`: 移除 Kokoro/ONNX 运行时、Intel/Rosetta 降级行为，并定义已移除模型设置与任务的安全迁移以及 Apple Silicon 模型的资源策略。

## Impact

- 构建与发布：`AudiobookMaker.xcodeproj` 的架构设置、Swift Package/二进制依赖、Metal 资源、签名公证流程、CI 和 Release 产物。
- TTS 领域与服务：模型目录、manifest、安装器、运行时客户端/工厂、平台探测、默认模型迁移、任务恢复和错误映射。
- 用户界面：模型菜单与详情、设置说明、许可链接、平台错误文案、UI/验收测试入口。
- 依赖与体积：移除 sherpa-onnx、ONNX Runtime、Kokoro 模型元数据及相关许可/SBOM 条目；保留 AVFoundation、speech-swift、MLX Swift 与 Metal。
- 兼容性：现有 Intel 用户无法升级到该版本；现有 Kokoro 默认设置与模型安装不再可用，Kokoro 生成中的任务不能跨模型透明续跑。
- 文档与测试：README、隐私/分发/第三方说明、架构验收、模型安装与运行时测试需要同步更新。