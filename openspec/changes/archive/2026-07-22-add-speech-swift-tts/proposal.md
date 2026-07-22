## Why

Kokoro 目前是唯一可下载的高质量本地模型，Apple Silicon 设备没有利用 MLX/CoreML 的原生推理能力，也无法选择 CosyVoice3 或 Qwen3-TTS。通过 speech-swift 增加这两个模型，可以在不改变现有有声书工作流的前提下，为 Apple Silicon 用户提供更高质量、更多语言与音色选择的完全本地 TTS。

## What Changes

- 固定并集成一个经过验证的 `soniqo/speech-swift` 版本，只链接所需的 `CosyVoiceTTS`、`Qwen3TTS` 及共享模块，并正确打包 MLX Metal 运行资源。
- 仅在原生 Apple Silicon 且满足 speech-swift 最低系统要求的环境中展示 CosyVoice3 和 Qwen3-TTS；Intel/Rosetta 或不兼容系统继续只提供 Apple 系统语音与 Kokoro，并显示明确的不可用原因而不尝试加载 MLX。
- 将 CosyVoice3 与 Qwen3-TTS 纳入现有签名模型清单、用户触发下载、进度、取消、校验、原子安装、损坏修复与离线使用流程，模型权重不进入 App bundle。
- 通过现有 `TTSRuntimeClient` 路由 speech-swift 合成，统一处理能力协商、长文本切片、取消、错误、音频校验、队列并发和任务恢复。
- 在“模型”界面复用 Kokoro 的详情交互：安装状态、设为默认、稳定音色选择、搜索、试听、失败重试和许可信息；仅暴露适合有声书的预置/稳定音色，不在本次加入录音、零样本克隆、多说话人对话或自由风格指令 UI。
- 扩展持久化迁移和任务锁定，使 CosyVoice3、Qwen3-TTS 的 model ID、版本与 voice ID 在设置、转换和恢复期间保持一致。
- 增加 Apple Silicon 实机的模型下载、冷加载、试听、长章节转换、暂停/取消、内存与 RTF 验收，并验证 Intel/Rosetta 环境不会暴露或加载 speech-swift 模型。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `tts-model-runtime`: 模型目录按设备能力提供 speech-swift CosyVoice3/Qwen3-TTS，并将两者接入统一音色、试听、合成、取消和错误契约。
- `tts-model-installation`: 将单一 Kokoro 安装流程扩展为多模型、分版本的签名下载与离线安装流程，并增加 Apple Silicon/system compatibility 门禁。
- `conversion-queue-recovery`: 允许任务锁定并恢复 speech-swift 模型选择，且按高内存运行时能力限制并发。
- `local-data-privacy`: 将网络与离线隐私约束扩展到所有可下载 TTS 模型和 speech-swift 本地运行时。

## Impact

- 影响模型目录、设置与模型详情 UI、持久化模型记录、`RoutingTTSRuntimeClient`、模型包管理器、转换/恢复协调器和 M4B 旁白元数据。
- 新增 speech-swift Swift Package 依赖及其 MLX/CoreML/Metal 运行资源；需要固定版本、许可证、Notice、SBOM、签名与 Release 打包验证。
- 模型下载体积和峰值内存显著增加；Qwen3-TTS 必须遵守运行时 token/长文本限制，CosyVoice3 与 Qwen3-TTS 默认并发不得超过各自运行时报告的安全上限。
- App 的最低系统版本已高于 speech-swift 当前 macOS 15 要求，但新增能力仍只在原生 arm64 环境启用；现有 Kokoro 双架构支持保持不变。
