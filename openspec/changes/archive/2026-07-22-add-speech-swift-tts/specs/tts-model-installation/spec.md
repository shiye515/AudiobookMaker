## MODIFIED Requirements

### Requirement: Kokoro 模型在 App 安装后由用户按需下载
系统 SHALL 在 App bundle 外提供 Kokoro，并在兼容的原生 Apple Silicon 环境中提供 CosyVoice3 与 Qwen3-TTS 模型包，MUST NOT 将任何模型权重编译或复制进 App bundle，且 SHALL 仅在用户对特定模型明确执行下载后开始联网。

#### Scenario: 新安装首次打开模型菜单
- **WHEN** 用户安装 App 后首次打开“模型”且尚未下载任何外部模型
- **THEN** 系统显示当前平台支持的模型、各自预计下载大小和“下载”操作，同时 Apple 系统语音保持可用

#### Scenario: 用户确认下载
- **WHEN** 用户对平台兼容且未安装的 Kokoro、CosyVoice3 或 Qwen3-TTS 执行“下载”
- **THEN** 系统只开始该模型的下载，并展示进度、取消入口、目标模型版本与所需磁盘空间

#### Scenario: 用户未请求下载
- **WHEN** 用户从未对某个模型执行下载
- **THEN** 系统不产生该模型的网络请求且不在 App bundle 或模型目录创建权重副本

### Requirement: 模型下载由受信版本清单约束
系统 SHALL 通过随 App 签名的版本化清单限定模型 ID、变体、平台要求、运行时 revision、HTTPS 来源与允许的重定向来源、总大小、包结构、最低运行时版本和许可元数据，并 SHALL 为归档或 snapshot 中的每个 artifact 固定相对路径、大小与 SHA-256，MUST 拒绝不符合清单的内容。

#### Scenario: 下载包哈希匹配
- **WHEN** 模型的全部归档或 snapshot artifacts 下载完成且各自大小与 SHA-256 均与对应清单一致
- **THEN** 系统进入安全解包和安装验证阶段

#### Scenario: 下载包哈希不匹配
- **WHEN** 任一归档或 snapshot artifact 下载完成但大小或 SHA-256 与对应清单不一致
- **THEN** 系统删除不可信 staging 产物、只将该模型标记安装失败并允许重新下载

#### Scenario: 运行时版本不足
- **WHEN** 模型包要求的 sherpa-onnx 或 speech-swift revision 高于当前 App 固定版本
- **THEN** 系统拒绝加载并提示更新 App，而不尝试执行不兼容模型

### Requirement: 模型安装安全且原子化
系统 MUST 在受控 staging 目录处理模型内容：归档 artifact 按 manifest 声明的 archive root 解包，snapshot artifacts 只写入签名相对路径；系统 MUST 拒绝路径逃逸、绝对路径、符号链接、异常展开大小和缺失必需文件，并 SHALL 在全部 artifact 完整性、平台兼容性与目标运行时探测通过后以原子操作提交该模型版本目录。

#### Scenario: 模型包包含路径逃逸
- **WHEN** 任一模型压缩条目或 snapshot 相对路径解析到 staging 目录之外
- **THEN** 系统终止该模型安装、清理 staging 且保留所有现有已安装版本不变

#### Scenario: 安装验证成功
- **WHEN** 文件清单、许可文件、音色或 tokenizer/codec 资源、平台检查和运行时探测全部成功
- **THEN** 系统原子提交该版本并将对应模型状态改为 installed 和 ready

#### Scenario: 安装中断
- **WHEN** App 在任一模型验证或提交前退出
- **THEN** 下次启动按 model ID 清理或恢复 staging，且不得把不完整目录报告为已安装

### Requirement: 下载失败可以取消和恢复
系统 SHALL 支持用户按 model ID 取消活动下载，并 SHALL 在来源与清单仍匹配时利用该模型的有效 resume data 继续；无效断点 MUST 回退为完整重试且不得影响其他模型状态。

#### Scenario: 用户取消下载
- **WHEN** 用户取消正在下载的某个模型
- **THEN** 系统停止该模型网络传输、保存可用断点信息并将其保持为未安装

#### Scenario: 网络中断后重试
- **WHEN** 某个模型下载因瞬时网络错误失败且用户执行重试
- **THEN** 系统优先从该模型有效断点继续并持续展示准确进度

#### Scenario: 断点与当前清单不匹配
- **WHEN** 已保存断点属于不同 URL、模型 ID、版本、变体或校验值
- **THEN** 系统丢弃断点并从头下载当前清单指定包

### Requirement: 已安装模型可离线使用
系统 SHALL 将成功安装的 Kokoro、CosyVoice3 与 Qwen3-TTS 保存在 App 管理的分模型、分版本 Application Support 目录，并 SHALL 禁止 speech-swift 在合成时隐式下载，使已安装模型在无网络时仍可选择、试听和转换。

#### Scenario: 安装后断开网络
- **WHEN** 平台兼容且目标模型已安装，用户在离线状态打开 App
- **THEN** 系统从本地验证后的版本目录加载音色及运行资源并允许合成

#### Scenario: 本地模型文件损坏
- **WHEN** 启动或加载探测发现任一已安装模型的必需文件缺失或校验失败
- **THEN** 系统只将该模型版本标记为损坏且不可用，并提供重新下载操作

## ADDED Requirements

### Requirement: speech-swift 模型安装受平台兼容性约束
系统 SHALL 仅在原生 Apple Silicon、受支持 macOS 版本且 Metal 运行环境可用时允许下载、安装或加载 CosyVoice3 与 Qwen3-TTS，并 MUST NOT 在 Intel 或 Rosetta 进程中初始化 MLX 运行时。

#### Scenario: Apple Silicon 原生进程
- **WHEN** 平台检查确认 arm64 原生进程、系统版本和 Metal 能力满足固定 speech-swift 版本要求
- **THEN** 系统允许用户下载并安装清单中兼容的 speech-swift 模型

#### Scenario: Rosetta 翻译进程
- **WHEN** App 在 Apple Silicon 硬件上以 Rosetta x86_64 进程运行
- **THEN** 系统将 speech-swift 模型标记为平台不支持，不发起下载且不加载 MLX

### Requirement: 模型安装前检查磁盘容量
系统 SHALL 在开始或恢复 GB 级模型下载前，根据清单的下载大小、展开大小、staging 与安全余量检查可用磁盘空间，并 SHALL 在空间不足时保持现有安装不变。

#### Scenario: 磁盘空间不足
- **WHEN** 可用容量不足以容纳下载、staging、原子提交和安全余量
- **THEN** 系统拒绝开始或恢复下载，显示所需与可用容量且不删除现有模型
