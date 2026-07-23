## ADDED Requirements

### Requirement: 发布产物仅支持原生 Apple Silicon
系统 SHALL 只构建、签名、公证和发布 arm64 macOS 应用，且主可执行文件、嵌入 framework、动态库和辅助可执行文件 MUST NOT 包含 x86_64 slice；系统 MUST NOT 发布 Universal 2、Intel 或要求 Rosetta 的替代产物。

#### Scenario: 验证归档架构
- **WHEN** Release archive 完成并进入签名或发布门禁
- **THEN** 自动检查确认 App bundle 内所有 Mach-O 代码仅包含 arm64，否则发布失败

#### Scenario: Intel Mac 获取新版本
- **WHEN** 设备架构不满足 arm64 应用的系统安装或启动要求
- **THEN** 新版本不作为兼容更新提供且不得通过 Rosetta 降级运行

### Requirement: 发行包不包含已移除运行时
系统 MUST NOT 编译、链接、嵌入或分发 Kokoro、sherpa-onnx、ONNX Runtime 及其专属模型清单、音色、资源或辅助可执行文件，并 SHALL 在发布门禁检查链接依赖和 App bundle 内容。

#### Scenario: 检查链接与嵌入依赖
- **WHEN** 系统验证候选 Release archive
- **THEN** 链接图和 bundle 扫描均找不到 Sherpa/ONNX framework、动态库或 Kokoro 运行资源，否则发布失败

#### Scenario: 使用保留的 Apple 运行时
- **WHEN** 候选版本包含 Apple 系统语音或 speech-swift/MLX/Metal 所需代码与资源
- **THEN** 系统继续按固定版本、签名、公证和许可要求验证这些受支持依赖

### Requirement: Apple Silicon 性能具有可重复发布基线
系统 SHALL 在固定 Apple Silicon 设备、系统版本、Release 配置、模型 revision 和基准语料上测量应用体积、模型加载时间、首段首音频时间、稳态合成吞吐、峰值常驻内存与失败率，并 MUST 阻止关键指标超出已批准回归门限的版本发布。

#### Scenario: 候选版本满足性能门限
- **WHEN** 候选 Release 在规定的冷启动与热启动基准中完成全部采样且关键指标未超过批准的回归门限
- **THEN** 系统保存可追溯结果并允许通过性能发布门禁

#### Scenario: 候选版本发生性能回归
- **WHEN** 任一关键指标超过批准门限或基准条件、样本数不完整
- **THEN** 性能门禁失败并报告设备、构建、模型、语料和超限指标，且不得以不可比较的数据更新基线

### Requirement: Apple Silicon 运行环境在初始化前通过验证
系统 SHALL 在初始化 speech-swift、MLX 或 Metal 模型前确认原生 arm64、最低 macOS 版本、Metal 能力和运行时资源完整；验证失败 MUST 返回稳定的不可用错误且 MUST NOT开始模型下载或推理。

#### Scenario: 受支持环境启动 AI 模型
- **WHEN** 原生 arm64 进程满足系统、Metal 和运行时资源要求且模型已验证安装
- **THEN** 系统允许初始化目标 speech-swift 模型并执行本地推理

#### Scenario: 测试夹具模拟运行环境不完整
- **WHEN** 平台探测发现 Metal 不可用、系统版本不足或运行时资源缺失
- **THEN** 系统在初始化 MLX 前停止并返回可操作的平台或安装错误
