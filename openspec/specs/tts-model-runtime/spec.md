# tts-model-runtime Specification

## Purpose
定义 App 与本地 TTS 运行时之间的模型目录、能力协商、音色选择、试听、合成请求、取消、错误处理和大音频传输契约，使不同语音框架保持统一且安全的业务行为。

## Requirements

### Requirement: 系统提供统一模型目录
系统 SHALL 展示运行时报告的模型名称、标识、框架、版本、安装状态、加载状态和能力，并 SHALL 包含 Apple 系统语音及 `sherpa-onnx/kokoro-multi-lang-v1_1-int8`，MUST NOT 再提供 CosyVoice、CosyVoice3 或 MLX 模型目录项。

#### Scenario: Kokoro 已安装且运行时可加载
- **WHEN** 运行时报告指定 Kokoro 版本已安装、校验通过且可加载
- **THEN** 系统将其显示为可用模型并允许选择音色、试听和设为默认

#### Scenario: Kokoro 尚未安装
- **WHEN** 模型目录报告 Kokoro 为 notInstalled
- **THEN** 系统显示下载操作且禁用设为默认、试听和正式转换

#### Scenario: 旧 CosyVoice 默认值存在
- **WHEN** 升级时持久化设置仍引用 CosyVoice、CosyVoice3 或 MLX 模型 ID
- **THEN** 系统迁移到可用的 Apple 系统语音且模型目录不再显示旧模型

### Requirement: 用户可以选择默认模型
系统 SHALL 保证任一时刻最多只有一个默认 TTS 模型，并 SHALL 为每个模型保存最近选择的有效音色；默认模型或音色变更 SHALL 只影响变更后创建的新任务。

#### Scenario: 将已安装 Kokoro 设为默认
- **WHEN** 用户选择已安装且 ready 的 Kokoro 并指定有效音色
- **THEN** 系统保存 Kokoro 模型 ID、版本和音色 ID，取消旧默认标记并用于后续新任务

#### Scenario: 尝试选择未安装 Kokoro
- **WHEN** 用户查看未安装或损坏的 Kokoro
- **THEN** 系统禁止将其设为默认并提供下载或修复操作

#### Scenario: 任务运行期间切换模型或音色
- **WHEN** 用户在任务运行期间改变默认模型或 Kokoro 音色
- **THEN** 运行任务继续使用创建时固定的模型 ID、模型版本和音色 ID

### Requirement: App 与运行时协商版本和能力
系统 SHALL 在允许转换或试听前完成运行时健康、协议版本和能力握手，并 SHALL 获取支持语言、最大文本长度、输出格式、取消能力、建议并发数、模型版本及音色目录。

#### Scenario: Kokoro 握手兼容
- **WHEN** sherpa-onnx 协议兼容且返回有效 Kokoro 模型版本和至少一个音色
- **THEN** 系统根据能力启用模型加载、音色选择、试听与转换

#### Scenario: 运行时版本不兼容
- **WHEN** 运行时协议或已安装模型版本不受 App 支持
- **THEN** 系统禁用试听和转换并显示“需要更新 App 或重新下载模型”的可操作状态

#### Scenario: 音色目录无效
- **WHEN** 运行时返回重复、空白或模型未声明的 voice ID
- **THEN** 系统拒绝该音色目录并将模型标记为不可用

### Requirement: 合成请求与框架实现解耦
系统 SHALL 通过统一 `TTSRuntimeClient` 发送包含请求 ID、用途、章节 ID、片段序号、文本、模型 ID、模型版本、音色 ID、语言、输出格式和文本哈希的请求，且 App 业务逻辑 MUST NOT 针对 AVFoundation、sherpa-onnx 或 Kokoro 编写流程分支。

#### Scenario: 章节超过模型文本上限
- **WHEN** 章节文本长度超过运行时声明的最大长度
- **THEN** 系统按能力安全切片、以同一模型版本和音色顺序请求并按原顺序合并结果

#### Scenario: 运行时返回音频
- **WHEN** 运行时成功完成一个片段
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
