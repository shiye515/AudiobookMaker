## 1. 固定依赖与首发模型变体

- [ ] 1.1 在隔离 spike 中以原生 arm64 构建 speech-swift 的 `CosyVoiceTTS`、`Qwen3TTS` 与必要共享模块，验证 Swift 6、当前 Xcode/macOS deployment target 和 Release 配置兼容
- [ ] 1.2 比较 Qwen3-TTS 0.6B CustomVoice、1.7B 8-bit 与可用 CoreML 变体的中文质量、预置 speaker、下载大小、峰值内存和许可证，记录并确定一个首发变体
- [ ] 1.3 比较 CosyVoice3 受支持 3.0 系列的量化变体，确认无需参考录音的 default voice 行为并确定一个首发变体
- [ ] 1.4 固定 speech-swift release tag、resolved revision 与传递依赖版本，禁止产品构建跟踪 `main` 分支
- [ ] 1.5 验证并打包 MLX 所需 Metal shader library，增加 Release 构建检查以捕获缺失 metallib
- [ ] 1.6 更新第三方许可证、Notice 与 SBOM，记录 speech-swift、MLX Swift、CosyVoice3、Qwen3-TTS、tokenizer/codec 和模型权重的来源与授权

## 2. 实现平台能力门禁

- [ ] 2.1 新增可注入的 `SpeechSwiftPlatformSupport`，检测原生 arm64 进程、Rosetta 翻译、最低 macOS 版本和 Metal 可用性
- [ ] 2.2 为 arm64、Intel、Rosetta、旧系统和 Metal 不可用结果添加确定性单元测试
- [ ] 2.3 扩展模型展示状态与稳定错误，区分未安装、损坏、运行时不兼容和“需要原生 Apple Silicon”
- [ ] 2.4 确保不兼容环境不会构造 speech-swift runtime、解析远程模型或发起模型下载，并添加负向集成测试

## 3. 泛化签名模型清单与安装器

- [ ] 3.1 将 `TTSModelCatalog.kokoro` 单例重构为按稳定 model ID 索引的 manifest 集合，保留现有 Kokoro ID 与行为
- [ ] 3.2 扩展 manifest 以包含变体、平台要求、runtime revision、archive root、许可、磁盘预算及允许的 origin/redirect hosts，并更新签名 payload/version
- [ ] 3.3 为固定的 CosyVoice3 与 Qwen3-TTS 变体生成可复验的下载大小、展开大小、SHA-256、必需路径和签名清单
- [ ] 3.4 移除 `ModelPackageManager` 对 Kokoro archive root 的硬编码，按 manifest 安全定位、校验并原子提交任意模型包
- [ ] 3.5 将下载、进度、取消、resume data、staging 恢复和错误事件按 model ID 隔离，并防止一个模型状态污染另一个模型
- [ ] 3.6 在下载/恢复前实现下载大小、展开大小、staging 和安全余量的可用磁盘检查
- [ ] 3.7 将下载器白名单改为每份签名 manifest 的 HTTPS origin/redirect 集合，并覆盖 Hugging Face/CDN 合法重定向与未授权跳转测试
- [ ] 3.8 强制 speech-swift 从已验证的本地版本目录加载，测试缺文件时不会调用 `fromPretrained()` 隐式联网而是进入损坏/修复状态
- [ ] 3.9 增加多模型安装测试，覆盖并行操作拒绝或排队、取消恢复、哈希不符、路径逃逸、空间不足、原子替换、启动恢复和离线校验

## 4. 接入 speech-swift 运行时

- [ ] 4.1 新增 `SpeechSwiftTTSRuntimeClient` actor 与可替换 session factory，按 model ID 延迟加载并串行管理 CosyVoice3/Qwen3-TTS session
- [ ] 4.2 实现 CosyVoice3 本地模型加载、能力握手、default/稳定 voice 映射、语言选择和 24 kHz 合成
- [ ] 4.3 实现 Qwen3-TTS 本地模型加载、能力握手、预置/default voice 映射、语言选择和 24 kHz 合成
- [ ] 4.4 将 speech-swift Float PCM/WAV 安全写入受控 CAF/PCM 路径，并复用格式、采样率、声道、帧数和输出路径校验
- [ ] 4.5 扩展 `RoutingTTSRuntimeClient` 按稳定 ID 路由 system、Kokoro、CosyVoice3 和 Qwen3-TTS，未知或平台不兼容 ID 返回稳定错误
- [ ] 4.6 实现 session 释放与模型切换策略，确保两个高内存模型不同时驻留且 `recommendedConcurrency` 初始为 1
- [ ] 4.7 实现协作式取消与晚到结果丢弃，区分即时取消和“当前安全片段完成后取消”能力
- [ ] 4.8 为两个适配器增加确定性测试，覆盖加载失败、版本不匹配、无效 voice、文本上限、取消、超时、无效音频和资源释放

## 5. 长文本、队列与恢复

- [ ] 5.1 为 `RuntimeCapabilities` 增加平台支持、运行时文本/token 预算、内存等级与取消安全边界，同时保持现有 runtime 测试兼容
- [ ] 5.2 在句子边界实现 speech-swift 二级切片，使 Qwen3-TTS 请求低于 KV-cache/token/约 40 秒安全预算，并为 CosyVoice3 使用实测稳定上限
- [ ] 5.3 确保二级切片输出按序合并且每片保持同一 model ID、version、voice ID、语言与文本哈希
- [ ] 5.4 扩展调度器，使高内存 speech-swift 任务和试听共享单一安全配额，模型切换前等待当前片段并释放旧 session
- [ ] 5.5 扩展暂停/恢复校验，在模型缺失、损坏、voice 失效或当前平台不兼容时保持暂停并禁止静默回退
- [ ] 5.6 阻止清理仍被未完成任务引用的 CosyVoice3/Qwen3-TTS 版本，并增加升级、删除与跨设备恢复测试

## 6. 扩展模型界面与持久化

- [ ] 6.1 让模型列表、设置 Picker、快捷菜单和 M4B 旁白名称从统一模型目录生成，移除仅针对 Kokoro 的硬编码分支
- [ ] 6.2 在原生 Apple Silicon 上为 CosyVoice3/Qwen3-TTS 复用 Kokoro 模型详情的大小、下载、进度、取消、修复、默认模型和许可交互
- [ ] 6.3 在不兼容环境中隐藏 speech-swift 下载操作并展示“需要原生 Apple Silicon”，确认 Apple 系统语音与 Kokoro 仍可选择
- [ ] 6.4 为两个模型展示可搜索的稳定 voice/default voice 目录，持久化每模型最近一次有效选择且不显示克隆、录音或风格控件
- [ ] 6.5 复用固定本地化短句实现 speech-swift 试听、停止、新试听抢占、错误恢复和临时文件清理
- [ ] 6.6 增加持久化迁移，保留 system/Kokoro 设置并确保旧 CosyVoice/MLX 占位 ID 不会自动映射到新的 speech-swift ID
- [ ] 6.7 添加 SwiftUI/UI 测试，覆盖平台条件目录、下载状态、默认模型、音色搜索、试听并发、键盘操作和 VoiceOver 标签

## 7. 隐私、文档与发布门禁

- [ ] 7.1 扩展隐私日志和网络测试，证明书籍正文、文件名、试听文本、voice 设置与生成音频不会进入 speech-swift 模型下载请求或日志
- [ ] 7.2 增加 App bundle 扫描，确认不包含 CosyVoice3/Qwen3-TTS 权重、参考声音或缓存，同时验证所需 Metal 资源存在
- [ ] 7.3 更新 requirements、design、runtime distribution、privacy、用户帮助和回滚说明，描述平台限制、模型大小、离线行为与非即时取消
- [ ] 7.4 在原生 Apple Silicon 实机分别完成两个模型的下载、冷/热加载、固定试听、中文 EPUB、长章节、暂停/取消、离线重启和 M4B 端到端测试
- [ ] 7.5 记录两个模型的首段延迟、RTF、峰值内存、磁盘占用、长任务稳定性与 session 切换释放结果，超出安全阈值时阻止发布对应变体
- [ ] 7.6 在 Intel Mac 与 Apple Silicon Rosetta 进程验证 speech-swift 模型不可下载/加载且 Kokoro 转换正常
- [ ] 7.7 完成中文数字、日期、专名、中英混排和章节边界的人工听感验收，并冻结每个模型的默认 voice 与试听样句
- [ ] 7.8 对最终 universal Release archive 完成依赖解析复现、签名、公证、sandbox 联网安装、断网合成和回滚开关验证
