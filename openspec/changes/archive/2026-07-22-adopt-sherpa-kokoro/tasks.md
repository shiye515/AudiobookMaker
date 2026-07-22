## 1. 固定依赖与模型清单

- [x] 1.1 固定 sherpa-onnx 与 ONNX Runtime 源码版本，记录许可证、Notice、SBOM 和可复现构建命令
- [x] 1.2 构建并验证同时包含 x86_64 与 arm64 slice 的签名 XCFramework，确认 Xcode Release 配置可链接
- [x] 1.3 定义 `sherpa-onnx/kokoro-multi-lang-v1_1-int8` 的签名内置清单，包含 URL、版本、下载/展开大小、SHA-256、必需文件和最低运行时版本
- [x] 1.4 增加构建测试，断言 App bundle 不包含 Kokoro ONNX 权重、`voices.bin` 或完整模型资源

## 2. 迁移领域模型与持久化

- [x] 2.1 扩展模型安装/运行状态以覆盖 downloading、verifying、installing、installed、failed、corrupted 和下载进度
- [x] 2.2 为模型能力、音色目录和设置快照增加稳定 model version、voice ID、显示名和语言元数据
- [x] 2.3 为 ConversionJob、合成请求、结果校验和 checkpoint 增加 model ID、model version、voice ID 与 request purpose
- [x] 2.4 实现持久化迁移，将旧 CosyVoice/MLX 默认设置迁移为 Apple 系统语音，并保留进行中任务的历史诊断信息
- [x] 2.5 增加迁移与仓储测试，覆盖旧默认值、每模型最近音色和无效音色失效场景

## 3. 实现安全模型下载与安装

- [x] 3.1 在 Application Support 建立版本化 model、staging、resume-data 目录并限制所有路径解析在受控根目录内
- [x] 3.2 使用 `URLSessionDownloadTask` 实现用户触发下载、进度、取消、断点续传、重试和清单变化时的完整重下
- [x] 3.3 实现下载 URL/重定向白名单、大小限制和 SHA-256 校验，错误映射为稳定可恢复状态
- [x] 3.4 实现防路径逃逸的安全解包、必需文件/许可校验、运行时探测和同卷原子提交
- [x] 3.5 实现启动时 staging 恢复/清理和已安装模型损坏探测，确保不完整版本永不报告为 installed
- [x] 3.6 开启并审计 App Sandbox 网络客户端能力，确保下载请求不携带书籍或用户内容
- [x] 3.7 添加下载、错误重试、取消、哈希不符、压缩包攻击、安装中断、损坏修复和离线加载测试

## 4. 集成 sherpa-onnx Kokoro 运行时

- [x] 4.1 新增隔离的 sherpa-onnx 语音服务/适配器，通过现有 `TTSRuntimeClient` 边界暴露握手、模型探测、音色目录、合成和取消
- [x] 4.2 将 Kokoro 模型目录配置为已验证的外部版本路径，禁止运行时从 App bundle 或任意用户路径加载权重
- [x] 4.3 将稳定 voice ID 映射到 Kokoro speaker ID，并验证重复、空白、越界和版本不匹配的音色目录
- [x] 4.4 实现中文/英文文本规范化、能力上限、分片合成和 CAF/PCM 输出校验
- [x] 4.5 统一 Apple 系统语音与 Kokoro 的模型/音色请求契约，保持队列业务逻辑无框架特定分支
- [ ] 4.6 添加确定性适配器测试和真实 Kokoro 冒烟测试，覆盖 x86_64 CPU 与 arm64 运行、取消、超时、连接失效和无效音频

## 5. 实现模型菜单和音色试听

- [x] 5.1 用仓储驱动的 Apple 系统语音与 Kokoro 条目替换静态 CosyVoice 模型列表和设置 Picker
- [x] 5.2 在模型详情实现未安装大小提示、下载、进度、取消、校验/安装状态、失败原因、重试和离线已安装状态
- [x] 5.3 在 Kokoro ready 后展示可搜索的音色 Picker、语言元数据并持久化该模型最近一次有效音色
- [x] 5.4 实现本地化固定样句试听、生成/播放/停止状态、新试听抢占旧试听和临时文件清理
- [x] 5.5 在正式转换占满运行时并发时禁用试听并提供清晰说明
- [x] 5.6 为下载状态、默认模型切换、键盘操作、VoiceOver、音色选择和试听失败增加 SwiftUI/UI 测试

## 6. 锁定转换任务并支持恢复

- [x] 6.1 创建任务时冻结当前 model ID、model version 和 voice ID，并在每个分片请求与 checkpoint 中传递同一三元组
- [x] 6.2 确保任务运行期间切换默认模型或音色只影响之后创建的任务
- [x] 6.3 恢复任务前验证锁定模型版本与音色，缺失时保持暂停并引导重新安装相同版本
- [x] 6.4 阻止模型安装器清理仍被未完成任务引用的模型版本
- [x] 6.5 增加运行中切换、暂停恢复、模型损坏、音色缺失和多书排队一致性测试

## 7. 移除 CosyVoice 并更新产品资料

- [x] 7.1 删除代码、持久化种子、模型 ID、界面文案、本地化和测试夹具中的 CosyVoice/CosyVoice3/MLX 产品入口
- [x] 7.2 更新 `docs/requirements.md`、`docs/design.md`、运行时分发说明和隐私说明，使 sherpa-onnx/Kokoro、外置下载及音色能力成为当前事实
- [x] 7.3 更新第三方许可展示，允许用户在模型详情查看 sherpa-onnx、ONNX Runtime、Kokoro 和随包资源的许可
- [x] 7.4 增加全仓扫描测试或 CI 检查，确认生产代码与当前文档不再引用已移除的 CosyVoice 模型

## 8. 双架构与端到端验收

- [x] 8.1 在 Intel Mac 测量模型下载、冷加载、峰值内存、首段延迟、RTF、长章节稳定性和取消响应
- [ ] 8.2 在 Apple Silicon Mac 重复相同基准，验证签名、公证、沙箱与运行时 slice 选择
- [x] 8.3 使用真实中文 EPUB 完成下载模型、选择音色、试听、全书转换、暂停恢复、M4B 封装和离线重启的端到端测试
- [ ] 8.4 对中文数字、日期、专名、中英混排和章节边界进行听感验收，并冻结默认音色与试听样句
- [x] 8.5 运行全部单元测试、UI 测试和 Release archive 验证，记录剩余性能限制与回滚开关
