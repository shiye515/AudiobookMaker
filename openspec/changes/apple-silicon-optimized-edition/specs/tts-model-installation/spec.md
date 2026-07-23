## ADDED Requirements

### Requirement: speech-swift 模型在 App 安装后由用户按需下载
系统 SHALL 在 App bundle 外提供 CosyVoice3 与 Qwen3-TTS 模型包，MUST NOT 将任何模型权重编译或复制进 App bundle，且 SHALL 仅在用户对特定模型明确执行下载后开始联网；Apple 系统语音 SHALL 无需模型下载即可使用。

#### Scenario: 新安装首次打开模型菜单
- **WHEN** 用户安装 Apple Silicon 版本后首次打开“模型”且尚未下载任何外部模型
- **THEN** 系统显示 CosyVoice3、Qwen3-TTS、各自预计下载大小和“下载”操作，同时 Apple 系统语音保持可用且不显示 Kokoro

#### Scenario: 用户确认下载
- **WHEN** 用户对平台兼容且未安装的 CosyVoice3 或 Qwen3-TTS 执行“下载”
- **THEN** 系统只开始该模型的下载，并展示进度、取消入口、目标模型版本与所需磁盘空间

#### Scenario: 用户未请求下载
- **WHEN** 用户从未对某个 speech-swift 模型执行下载
- **THEN** 系统不产生该模型的网络请求且不在 App bundle 或模型目录创建权重副本

## MODIFIED Requirements

### Requirement: 模型下载由受信版本清单约束
系统 SHALL 通过随 App 签名的版本化清单限定模型 ID、变体、平台要求、speech-swift revision、HTTPS 来源与允许的重定向来源、总大小、包结构、最低运行时版本和许可元数据，并 SHALL 为 snapshot 中的每个 artifact 固定相对路径、大小与 SHA-256，MUST 拒绝不符合清单的内容。

#### Scenario: 下载包哈希匹配
- **WHEN** 模型的全部 snapshot artifacts 下载完成且各自大小与 SHA-256 均与对应清单一致
- **THEN** 系统进入安全安装验证阶段

#### Scenario: 下载包哈希不匹配
- **WHEN** 任一 snapshot artifact 下载完成但大小或 SHA-256 与对应清单不一致
- **THEN** 系统删除不可信 staging 产物、只将该模型标记安装失败并允许重新下载

#### Scenario: 运行时版本不足
- **WHEN** 模型包要求的 speech-swift revision 高于当前 App 固定版本
- **THEN** 系统拒绝加载并提示更新 App，而不尝试执行不兼容模型

### Requirement: 已安装模型可离线使用
系统 SHALL 将成功安装的 CosyVoice3 与 Qwen3-TTS 保存在 App 管理的分模型、分版本 Application Support 目录，并 SHALL 禁止 speech-swift 在合成时隐式下载，使已安装模型在无网络时仍可选择、试听和转换。

#### Scenario: 安装后断开网络
- **WHEN** 目标模型已安装且平台运行环境有效，用户在离线状态打开 App
- **THEN** 系统从本地验证后的版本目录加载音色及运行资源并允许合成

#### Scenario: 本地模型文件损坏
- **WHEN** 启动或加载探测发现任一已安装模型的必需文件缺失或校验失败
- **THEN** 系统只将该模型版本标记为损坏且不可用，并提供重新下载操作

### Requirement: speech-swift 模型安装受平台兼容性约束
系统 SHALL 仅在原生 Apple Silicon、受支持 macOS 版本且 Metal 运行环境可用时允许下载、安装或加载 CosyVoice3 与 Qwen3-TTS，并 MUST 在任何平台验证失败时阻止初始化 MLX 运行时。

#### Scenario: Apple Silicon 原生进程
- **WHEN** 平台检查确认 arm64 原生进程、系统版本和 Metal 能力满足固定 speech-swift 版本要求
- **THEN** 系统允许用户下载并安装清单中兼容的 speech-swift 模型

#### Scenario: 运行环境检查失败
- **WHEN** 测试或损坏环境表明进程、系统版本或 Metal 能力不满足要求
- **THEN** 系统将 speech-swift 模型标记为平台不支持，不发起下载且不加载 MLX

## REMOVED Requirements

### Requirement: Kokoro 模型在 App 安装后由用户按需下载
**Reason**: Apple Silicon 专用版本移除 Kokoro、sherpa-onnx 和 ONNX Runtime，不再维护 CPU/跨架构模型供应链。
**Migration**: 用户改用 Apple 系统语音，或按需下载 CosyVoice3/Qwen3-TTS；升级迁移会移除 Kokoro 安装状态、断点数据和经安全路径验证的托管模型目录。
