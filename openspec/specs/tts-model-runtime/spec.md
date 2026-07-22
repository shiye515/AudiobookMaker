# tts-model-runtime Specification

## Purpose
定义 App 与本地 TTS 运行时之间的模型目录、能力协商、音色选择、试听、合成请求、取消、错误处理和大音频传输契约，使不同语音框架保持统一且安全的业务行为。
## Requirements
### Requirement: 系统提供统一模型目录
系统 SHALL 展示运行时报告的模型名称、标识、框架、版本、安装状态、加载状态、平台可用性和能力，并 SHALL 始终包含 Apple 系统语音与 `sherpa-onnx/kokoro-multi-lang-v1_1-int8`；在兼容的原生 Apple Silicon 环境中还 SHALL 包含基于 speech-swift 的 CosyVoice3 与 Qwen3-TTS，MUST NOT 把旧版 CosyVoice/MLX 占位 ID 当作新的 speech-swift 模型。

#### Scenario: Kokoro 已安装且运行时可加载
- **WHEN** 运行时报告指定 Kokoro 版本已安装、校验通过且可加载
- **THEN** 系统将其显示为可用模型并允许选择音色、试听和设为默认

#### Scenario: Kokoro 尚未安装
- **WHEN** 模型目录报告 Kokoro 为 notInstalled
- **THEN** 系统显示下载操作且禁用设为默认、试听和正式转换

#### Scenario: 兼容的 Apple Silicon 环境
- **WHEN** App 以原生 arm64 运行且系统版本、Metal 与 speech-swift 运行要求全部满足
- **THEN** 模型目录展示 CosyVoice3 与 Qwen3-TTS，并按各自安装状态提供下载或使用操作

#### Scenario: Intel 或 Rosetta 环境
- **WHEN** App 运行在 Intel Mac、Rosetta 翻译进程或其他不兼容环境
- **THEN** 系统不提供 speech-swift 模型下载或加载入口，并说明这些模型需要原生 Apple Silicon，同时 Apple 系统语音与 Kokoro 保持可用

#### Scenario: 旧 CosyVoice 默认值存在
- **WHEN** 升级时持久化设置仍引用旧 CosyVoice、CosyVoice3 或 MLX 占位模型 ID
- **THEN** 系统迁移到可用的 Apple 系统语音且不得将旧 ID 自动映射到新的 speech-swift 模型

### Requirement: 用户可以选择默认模型
系统 SHALL 保证任一时刻最多只有一个默认 TTS 模型，并 SHALL 为每个模型保存最近选择的有效音色；默认模型或音色变更 SHALL 只影响变更后创建的新任务。

#### Scenario: 将已安装 Kokoro 设为默认
- **WHEN** 用户选择已安装且 ready 的 Kokoro 并指定有效音色
- **THEN** 系统保存 Kokoro 模型 ID、版本和音色 ID，取消旧默认标记并用于后续新任务

#### Scenario: 尝试选择未安装 Kokoro
- **WHEN** 用户查看未安装或损坏的 Kokoro
- **THEN** 系统禁止将其设为默认并提供下载或修复操作

#### Scenario: 将已安装的可下载模型设为默认
- **WHEN** 用户选择已安装且 ready 的 Kokoro、CosyVoice3 或 Qwen3-TTS 并指定有效音色
- **THEN** 系统保存其模型 ID、版本和音色 ID，取消旧默认标记并用于后续新任务

#### Scenario: 尝试选择未安装或平台不兼容的模型
- **WHEN** 用户查看未安装、损坏或当前设备不支持的可下载模型
- **THEN** 系统禁止将其设为默认，并仅在平台兼容时提供下载或修复操作

#### Scenario: 任务运行期间切换模型或音色
- **WHEN** 用户在任务运行期间改变默认模型或音色
- **THEN** 运行任务继续使用创建时固定的模型 ID、模型版本和音色 ID

### Requirement: App 与运行时协商版本和能力
系统 SHALL 在允许转换或试听前完成目标运行时的健康、平台、协议版本和能力握手，并 SHALL 获取支持语言、最大文本或 token 限制、输出格式、取消能力、建议并发数、模型版本及音色目录。

#### Scenario: Kokoro 握手兼容
- **WHEN** sherpa-onnx 协议兼容且返回有效 Kokoro 模型版本和至少一个音色
- **THEN** 系统根据能力启用模型加载、音色选择、试听与转换

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
系统 SHALL 通过统一 `TTSRuntimeClient` 发送包含请求 ID、用途、章节 ID、片段序号、文本、模型 ID、模型版本、音色 ID、语言、输出格式和文本哈希的请求，且 App 业务逻辑 MUST NOT 针对 AVFoundation、sherpa-onnx、speech-swift、Kokoro、CosyVoice3 或 Qwen3-TTS 编写流程分支。

#### Scenario: 章节超过模型文本上限
- **WHEN** 章节文本超过目标运行时声明的字符、token、KV-cache 或安全音频时长上限
- **THEN** 系统在句子安全边界切片、以同一模型版本和音色顺序请求并按原顺序合并结果

#### Scenario: 运行时返回音频
- **WHEN** 任一运行时成功完成一个片段
- **THEN** 系统校验音频格式、采样率、声道、帧数、模型版本、音色 ID 和文本哈希后保存 checkpoint

### Requirement: 运行时调用支持取消和明确错误
系统 SHALL 提供以 request ID 为单位的幂等取消，并 SHALL 将中断、失效、超时、模型缺失和无效音频映射为稳定领域错误。

#### Scenario: 重复取消同一请求
- **WHEN** 系统对同一 request ID 多次发出取消
- **THEN** 运行时边界安全返回且不会重复提交音频结果

#### Scenario: XPC 连接失效
- **WHEN** 合成过程中运行时连接失效
- **THEN** 系统停止创建新请求、保存可用 checkpoint 并显示可重试错误

### Requirement: 大音频不通过单次内存复制传输
系统 SHALL 使用受控临时文件或文件描述符在运行时边界传递大音频，MUST NOT 将整章音频作为单个 Data 消息复制。

#### Scenario: 合成长章节
- **WHEN** 运行时生成大于进程消息安全阈值的音频
- **THEN** 系统通过文件型通道接收结果且主进程内存不随整个音频大小等比例增长

### Requirement: Kokoro 提供可选择的音色目录
系统 SHALL 在 Kokoro 安装并 ready 后展示其稳定音色 ID、用户可读名称和可用语言提示，并 SHALL 允许用户为 Kokoro 指定一个音色。

#### Scenario: 打开已安装 Kokoro 详情
- **WHEN** 用户在“模型”菜单选择已安装的 Kokoro
- **THEN** 系统展示运行时确认的音色列表并选中该模型最近保存的有效音色

#### Scenario: 保存的音色已不存在
- **WHEN** 模型版本变化后原 voice ID 不在新音色目录中
- **THEN** 系统要求用户重新选择音色且不得静默开始新转换任务

### Requirement: 用户可以试听 Kokoro 音色
系统 SHALL 为每个可用 Kokoro 音色提供试听操作，使用本地化内置短文本生成和播放临时音频，并 MUST NOT 为试听创建书籍任务、checkpoint 或导出产物。

#### Scenario: 试听一个音色
- **WHEN** 用户对可用音色执行“试听”且没有正式转换占用运行时
- **THEN** 系统合成内置样句、校验音频并播放，同时展示可停止的试听状态

#### Scenario: 切换试听音色
- **WHEN** 一个试听仍在生成或播放且用户试听另一个音色
- **THEN** 系统取消或停止旧试听并仅保留新音色的试听状态

#### Scenario: 正式转换正在运行
- **WHEN** 运行时建议并发已被正式转换占满
- **THEN** 系统禁用试听并说明需等待当前转换暂停或完成

#### Scenario: 试听失败
- **WHEN** 试听合成、校验或播放失败
- **THEN** 系统清理试听临时文件、恢复可重试状态且不影响默认音色设置

### Requirement: speech-swift 模型提供稳定音色目录
系统 SHALL 为已安装且 ready 的 CosyVoice3 与 Qwen3-TTS 提供稳定 voice ID、用户可读名称和语言提示；如果所选模型变体只有一个无需参考音频的默认 speaker，系统 SHALL 将其表示为稳定的 default voice，MUST NOT 把需要用户录音或外部参考音频的克隆能力伪装成预置音色。

#### Scenario: 打开 speech-swift 模型详情
- **WHEN** 用户在兼容设备上打开已安装的 CosyVoice3 或 Qwen3-TTS
- **THEN** 系统展示运行时确认的音色列表并选中该模型最近保存的有效音色

#### Scenario: 模型不提供预置多音色
- **WHEN** 已安装变体只支持一个无需参考音频的默认 speaker
- **THEN** 系统展示单个 default 音色且不显示录音、克隆或外部音频入口

### Requirement: 用户可以试听 speech-swift 音色
系统 SHALL 复用 Kokoro 试听流程，为可用的 CosyVoice3 与 Qwen3-TTS 音色使用本地化固定短文本生成和播放临时音频，并 MUST NOT 创建书籍任务、checkpoint 或导出产物。

#### Scenario: 试听 speech-swift 音色
- **WHEN** 用户试听一个可用的 CosyVoice3 或 Qwen3-TTS 音色且正式转换未占满运行时
- **THEN** 系统在本机合成、校验并播放音频，同时提供停止状态和失败重试

#### Scenario: 正式转换占用高内存运行时
- **WHEN** CosyVoice3 或 Qwen3-TTS 的安全并发配额已被正式转换占满
- **THEN** 系统禁用试听并说明需等待当前片段暂停或完成

### Requirement: speech-swift 推理受资源安全限制
系统 SHALL 将 CosyVoice3 与 Qwen3-TTS 的默认建议并发限制为 1，并 SHALL 遵守运行时声明的 token、KV-cache、生成时长和取消安全边界，MUST NOT 以可能触发共享 GPU watchdog 的超长单次请求运行。

#### Scenario: Qwen3-TTS 长段落
- **WHEN** 输入可能超过 Qwen3-TTS 的 token、KV-cache 或安全生成时长预算
- **THEN** 系统在发送请求前进一步切分文本且每个子请求均保持同一模型、版本和音色

#### Scenario: 取消正在执行的 Metal 推理
- **WHEN** 上游运行时无法立即中止当前 Metal kernel
- **THEN** 系统停止创建后续请求、丢弃取消后晚到的结果并在安全边界结束当前工作

