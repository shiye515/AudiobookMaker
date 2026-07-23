## ADDED Requirements

### Requirement: 已移除模型的持久状态安全迁移
系统 SHALL 以版本化且幂等的迁移处理 Kokoro 模型 ID、音色 ID、安装记录、下载断点和任务快照；MUST NOT 将 Kokoro checkpoint 静默交给 Apple 系统语音、CosyVoice3 或 Qwen3-TTS 继续生成。

#### Scenario: 默认模型引用 Kokoro
- **WHEN** 升级后持久化默认模型或最近音色引用已移除的 Kokoro
- **THEN** 系统将默认模型迁移为 Apple 系统语音、清除 Kokoro 音色引用，并向用户说明原模型已移除

#### Scenario: 未完成任务绑定 Kokoro
- **WHEN** 排队、转换中、暂停或中断的任务快照引用 Kokoro 模型或版本
- **THEN** 系统保留书籍和任务元数据、将任务标记为模型已移除且需要重新开始，并禁止复用其旧合成 checkpoint

#### Scenario: 重复执行迁移
- **WHEN** 应用在迁移完成后再次启动
- **THEN** 系统不重复删除有效数据、不改变已迁移选择且保持相同任务状态

#### Scenario: 清理旧模型目录
- **WHEN** Kokoro 安装路径经规范化后确认位于 App 管理模型根目录且匹配已知模型 ID
- **THEN** 系统移除其安装记录、resume data 和托管模型文件；路径校验失败时跳过文件删除并记录错误

## MODIFIED Requirements

### Requirement: 系统提供统一模型目录
系统 SHALL 展示运行时报告的模型名称、标识、框架、版本、安装状态、加载状态、平台可用性和能力，并 SHALL 始终包含 Apple 系统语音、CosyVoice3 与 Qwen3-TTS；系统 MUST NOT 展示、下载或加载 Kokoro、旧版 CosyVoice/MLX 占位 ID 或其他已移除运行时。

#### Scenario: Apple Silicon 模型目录
- **WHEN** App 以受支持的原生 arm64 环境运行
- **THEN** 模型目录展示 Apple 系统语音、CosyVoice3 与 Qwen3-TTS，并按可下载模型各自安装状态提供下载或使用操作

#### Scenario: speech-swift 模型尚未安装
- **WHEN** 模型目录报告 CosyVoice3 或 Qwen3-TTS 为 notInstalled
- **THEN** 系统显示该模型的下载操作且禁用设为默认、试听和正式转换

#### Scenario: 目录或旧设置包含已移除模型 ID
- **WHEN** 运行时目录、升级设置或测试数据引用 Kokoro、旧 CosyVoice 或 MLX 占位模型 ID
- **THEN** 系统不将其作为可选模型展示，并按迁移规则回退到 Apple 系统语音

### Requirement: 用户可以选择默认模型
系统 SHALL 保证任一时刻最多只有一个默认 TTS 模型，并 SHALL 为每个受支持模型保存最近选择的有效音色；默认模型或音色变更 SHALL 只影响变更后创建的新任务。

#### Scenario: 将 Apple 系统语音设为默认
- **WHEN** 用户选择可用的 Apple 系统语音并指定有效音色
- **THEN** 系统保存系统模型与音色 ID，取消旧默认标记并用于后续新任务

#### Scenario: 将已安装的 speech-swift 模型设为默认
- **WHEN** 用户选择已安装且 ready 的 CosyVoice3 或 Qwen3-TTS 并指定有效音色
- **THEN** 系统保存其模型 ID、版本和音色 ID，取消旧默认标记并用于后续新任务

#### Scenario: 尝试选择未安装或不可用的模型
- **WHEN** 用户查看未安装、损坏或当前运行环境不支持的可下载模型
- **THEN** 系统禁止将其设为默认，并仅在运行环境兼容时提供下载或修复操作

#### Scenario: 任务运行期间切换模型或音色
- **WHEN** 用户在任务运行期间改变默认模型或音色
- **THEN** 运行任务继续使用创建时固定的模型 ID、模型版本和音色 ID

### Requirement: App 与运行时协商版本和能力
系统 SHALL 在允许转换或试听前完成目标运行时的健康、平台、协议版本和能力握手，并 SHALL 获取支持语言、最大文本或 token 限制、输出格式、取消能力、建议并发数、模型版本及音色目录。

#### Scenario: Apple 系统语音握手兼容
- **WHEN** Apple 系统语音后端健康且返回有效音色和输出能力
- **THEN** 系统根据能力启用音色选择、试听与转换

#### Scenario: speech-swift 握手兼容
- **WHEN** 原生 Apple Silicon 上的 speech-swift 版本与已安装 CosyVoice3 或 Qwen3-TTS manifest 匹配，并返回有效限制与音色目录
- **THEN** 系统根据该模型的能力启用加载、音色选择、试听与转换

#### Scenario: 运行时版本不兼容
- **WHEN** 运行时协议、speech-swift revision 或已安装模型版本不受 App 支持
- **THEN** 系统禁用试听和转换并显示“需要更新 App 或重新下载模型”的可操作状态

#### Scenario: 音色目录无效
- **WHEN** 任一运行时返回重复、空白或模型未声明的 voice ID
- **THEN** 系统拒绝该音色目录并将模型标记为不可用

### Requirement: 合成请求与框架实现解耦
系统 SHALL 通过统一 `TTSRuntimeClient` 发送包含请求 ID、用途、章节 ID、片段序号、文本、模型 ID、模型版本、音色 ID、语言、输出格式和文本哈希的请求，且 App 业务逻辑 MUST NOT 针对 AVFoundation、speech-swift、MLX、CosyVoice3 或 Qwen3-TTS 编写流程分支。

#### Scenario: 章节超过模型文本上限
- **WHEN** 章节文本超过目标运行时声明的字符、token、KV-cache 或安全音频时长上限
- **THEN** 系统在句子安全边界切片、以同一模型版本和音色顺序请求并按原顺序合并结果

#### Scenario: 运行时返回音频
- **WHEN** 任一运行时成功完成一个片段
- **THEN** 系统校验音频格式、采样率、声道、帧数、模型版本、音色 ID 和文本哈希后保存 checkpoint

### Requirement: 用户可以试听 speech-swift 音色
系统 SHALL 使用共享试听流程，为可用的 CosyVoice3 与 Qwen3-TTS 音色使用本地化固定短文本生成和播放临时音频，并 MUST NOT 创建书籍任务、checkpoint 或导出产物。

#### Scenario: 试听 speech-swift 音色
- **WHEN** 用户试听一个可用的 CosyVoice3 或 Qwen3-TTS 音色且正式转换未占满运行时
- **THEN** 系统在本机合成、校验并播放音频，同时提供停止状态和失败重试

#### Scenario: 正式转换占用高内存运行时
- **WHEN** CosyVoice3 或 Qwen3-TTS 的安全并发配额已被正式转换占满
- **THEN** 系统禁用试听并说明需等待当前片段暂停或完成

### Requirement: speech-swift 推理受资源安全限制
系统 SHALL 在运行时声明的安全上限内复用同一模型的已加载会话，将实际并发限制为配置值与运行时建议值中的较小者，并 SHALL 遵守 token、KV-cache、生成时长、内存压力和取消安全边界，MUST NOT 以可能触发共享 GPU watchdog 或内存耗尽的超长单次请求运行。

#### Scenario: 连续片段使用同一模型
- **WHEN** 同一任务连续提交相同模型与版本的兼容片段且未发生内存压力或不可恢复错误
- **THEN** 系统复用已验证的模型会话而不为每个片段重复完整加载

#### Scenario: Qwen3-TTS 长段落
- **WHEN** 输入可能超过 Qwen3-TTS 的 token、KV-cache 或安全生成时长预算
- **THEN** 系统在发送请求前进一步切分文本且每个子请求均保持同一模型、版本和音色

#### Scenario: 系统报告内存压力
- **WHEN** 当前没有必须占用模型的活动片段且系统报告需要释放内存
- **THEN** 系统安全卸载可重建的 MLX 模型会话并在后续请求重新验证加载

#### Scenario: 取消正在执行的 Metal 推理
- **WHEN** 上游运行时无法立即中止当前 Metal kernel
- **THEN** 系统停止创建后续请求、丢弃取消后晚到的结果并在安全边界结束当前工作

## REMOVED Requirements

### Requirement: Kokoro 提供可选择的音色目录
**Reason**: Apple Silicon 专用版本不再包含 Kokoro 模型或其 sherpa-onnx/ONNX Runtime 后端。
**Migration**: 已保存的 Kokoro 音色引用被清除；用户选择 Apple 系统语音、CosyVoice3 或 Qwen3-TTS 的有效音色。

### Requirement: 用户可以试听 Kokoro 音色
**Reason**: Kokoro 及其音色目录已从受支持模型目录移除，无法继续生成试听音频。
**Migration**: 试听入口仅面向 Apple 系统语音和已安装的 speech-swift 模型；升级时停止并清理未完成的 Kokoro 试听临时状态。
