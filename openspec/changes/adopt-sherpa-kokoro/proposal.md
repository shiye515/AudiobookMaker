## Why

当前模型目录仍以仅适用于 Apple Silicon 的 CosyVoice/MLX 占位为中心，无法满足 Intel 与 Apple 芯片统一运行、安装包轻量和可实际选择音色的产品要求。采用 sherpa-onnx 与 Kokoro 可以用同一套本地运行时覆盖两种架构，同时让模型在安装 App 后按需下载。

## What Changes

- **BREAKING**：从模型目录、设置、持久化默认值和运行时契约中移除 CosyVoice/CosyVoice3/MLX 模型及相关兼容性提示。
- 引入基于 sherpa-onnx 的 Kokoro 本地 TTS 运行时，首个模型包为支持中文和英文多音色的 `kokoro-multi-lang-v1_1`。
- App 安装包不携带 Kokoro 权重；用户安装 App 后从“模型”界面主动下载，下载完成并校验成功后方可选择使用。
- 在“模型”菜单中展示 Apple 系统语音和 Kokoro，允许切换默认模型，并清晰展示未下载、下载中、校验中、可用和失败状态。
- 下载并安装 Kokoro 后提供音色列表、音色选择和短文本试听；选定的模型与音色用于后续新建转换任务。
- 将模型 ID、模型版本和音色 ID 固定到任务及 checkpoint，避免任务期间切换设置造成同一本书混用音色。
- 模型下载网络访问与书籍正文、参考音频和生成音频严格隔离；转换仍完全在本机完成。

## Capabilities

### New Capabilities

- `tts-model-installation`: 定义 App 外置模型包的下载、完整性校验、原子安装、失败恢复和安装状态。

### Modified Capabilities

- `tts-model-runtime`: 将默认第三方运行时改为 sherpa-onnx/Kokoro，并增加音色目录、选择、试听以及模型与音色能力协商。
- `conversion-queue-recovery`: 转换任务除模型外还需锁定音色与模型版本，并在恢复时验证对应资源仍可用。
- `local-data-privacy`: 允许仅用于模型包下载的受限联网，同时保持书籍内容和生成音频不上传。

## Impact

- SwiftUI 模型列表、模型详情、设置窗口和 App 菜单需要替换 CosyVoice 占位，并加入下载进度、音色 Picker 与试听控件。
- `TTSRuntimeClient`、运行时能力、合成请求、持久化模型/设置/任务快照和 checkpoint 元数据需要增加模型版本、音色及安装状态字段。
- 新增 sherpa-onnx/ONNX Runtime 的 x86_64 与 arm64 原生运行时集成，以及 Kokoro 模型包管理器；模型权重不进入 App bundle。
- App Sandbox 需要受控的网络客户端能力和 Application Support 模型目录，并需完成依赖、模型许可、签名、公证和双架构验证。
- 现有 CosyVoice 标识、UI 文案、测试夹具和文档需要删除或迁移。
