# tts-model-installation Specification

## Purpose
定义 App 外部 TTS 模型包的用户触发下载、受信来源与版本校验、安全原子安装、断点恢复、损坏处理及离线使用要求，确保模型供应链和本地资源状态可验证、可恢复。

## Requirements

### Requirement: Kokoro 模型在 App 安装后由用户按需下载
系统 SHALL 在 App bundle 外提供 `sherpa-onnx/kokoro-multi-lang-v1_1-int8` 模型包，MUST NOT 将其权重编译或复制进 App bundle，且 SHALL 仅在用户明确执行下载后开始联网。

#### Scenario: 新安装首次打开模型菜单
- **WHEN** 用户安装 App 后首次打开“模型”且尚未下载 Kokoro
- **THEN** 系统显示 Kokoro、预计下载大小和“下载”操作，同时 Apple 系统语音保持可用

#### Scenario: 用户确认下载
- **WHEN** 用户对未安装的 Kokoro 执行“下载”
- **THEN** 系统开始下载并展示进度、取消入口和目标模型版本

#### Scenario: 用户未请求下载
- **WHEN** 用户从未执行 Kokoro 下载
- **THEN** 系统不产生模型网络请求且不在 App bundle 或模型目录创建权重副本

### Requirement: 模型下载由受信版本清单约束
系统 SHALL 通过随 App 签名的版本化清单限定模型 ID、版本、HTTPS 来源、大小、SHA-256、包结构、最低运行时版本和许可元数据，并 MUST 拒绝不符合清单的包。

#### Scenario: 下载包哈希匹配
- **WHEN** 下载完成且压缩包 SHA-256 与清单一致
- **THEN** 系统进入安全解包和安装验证阶段

#### Scenario: 下载包哈希不匹配
- **WHEN** 下载完成但 SHA-256 与清单不一致
- **THEN** 系统删除不可信 staging 产物、标记安装失败并允许重新下载

#### Scenario: 运行时版本不足
- **WHEN** 模型包要求的最低 sherpa-onnx 运行时高于当前版本
- **THEN** 系统拒绝加载并提示更新 App，而不尝试执行不兼容模型

### Requirement: 模型安装安全且原子化
系统 MUST 在受控 staging 目录解包，拒绝路径逃逸、绝对路径、符号链接、异常展开大小和缺失必需文件，并 SHALL 在完整性与运行时探测通过后以原子操作提交版本目录。

#### Scenario: 模型包包含路径逃逸
- **WHEN** 任一压缩条目解析到 staging 目录之外
- **THEN** 系统终止安装、清理 staging 且保留现有已安装版本不变

#### Scenario: 安装验证成功
- **WHEN** 文件清单、许可文件、音色资源和运行时探测全部成功
- **THEN** 系统原子提交该版本并将状态改为 installed 和 ready

#### Scenario: 安装中断
- **WHEN** App 在验证或提交前退出
- **THEN** 下次启动清理或恢复 staging，且不得把不完整目录报告为已安装

### Requirement: 下载失败可以取消和恢复
系统 SHALL 支持用户取消活动下载，并 SHALL 在来源与清单仍匹配时利用有效 resume data 继续；无效断点 MUST 回退为完整重试。

#### Scenario: 用户取消下载
- **WHEN** 用户取消正在下载的 Kokoro
- **THEN** 系统停止网络传输、保存可用断点信息并将模型保持为未安装

#### Scenario: 网络中断后重试
- **WHEN** 下载因瞬时网络错误失败且用户执行重试
- **THEN** 系统优先从有效断点继续并持续展示准确进度

#### Scenario: 断点与当前清单不匹配
- **WHEN** 已保存断点属于不同 URL、版本或校验值
- **THEN** 系统丢弃断点并从头下载当前清单指定包

### Requirement: 已安装模型可离线使用
系统 SHALL 将成功安装的模型保存在 App 管理的 Application Support 模型目录，并 SHALL 在无网络时继续允许选择、试听和转换。

#### Scenario: 安装后断开网络
- **WHEN** Kokoro 已安装且用户在离线状态打开 App
- **THEN** 系统从本地验证后的版本目录加载音色并允许合成

#### Scenario: 本地模型文件损坏
- **WHEN** 启动或加载探测发现必需文件缺失或校验失败
- **THEN** 系统将模型标记为损坏且不可用，并提供重新下载操作
