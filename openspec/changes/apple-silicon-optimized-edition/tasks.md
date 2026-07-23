## 1. 建立迁移与发布安全网

- [x] 1.1 为旧 Kokoro 默认模型、音色、安装状态、resume data 和排队/暂停/中断任务创建持久化测试夹具，覆盖迁移幂等性与禁止跨模型复用 checkpoint
- [x] 1.2 为托管模型目录清理添加路径规范化测试，验证只删除模型根目录内的已知 Kokoro 路径并对逃逸/异常路径失败关闭
- [x] 1.3 添加 Release archive 的 Mach-O 架构与链接/bundle 扫描脚本，递归验证所有可执行代码仅为 arm64 且不存在 Sherpa、ONNX 或 Kokoro 运行资源
- [ ] 1.4 建立 Apple Silicon Release 性能基准入口与结果格式，固定设备/系统/模型/语料及冷热启动定义，采集变更前的体积、加载、首音频、吞吐、峰值内存和失败率基线

## 2. 收敛模型目录与用户界面

- [x] 2.1 从 `TTSModelCatalog` 删除 Kokoro ID、manifest、下载 artifact、默认音色、音色目录和 `downloadableModels`/映射引用，仅保留 Apple 系统语音、CosyVoice3 与 Qwen3-TTS
- [x] 2.2 更新模型仓库、安装状态与运行时工厂，使已移除模型 ID 不可下载、安装、加载或成为默认值，并继续校验 speech-swift manifest、离线加载与平台要求
- [x] 2.3 移除 App Commands、通知、模型列表/详情、设置说明、试听样句、许可链接和导出旁白名称中的 Kokoro 专属分支与文案
- [x] 2.4 更新 UI 测试夹具和模型目录测试，断言新安装仅展示 Apple 系统语音、CosyVoice3 与 Qwen3-TTS，且未安装模型只能按需触发各自下载

## 3. 实现旧版本安全迁移

- [x] 3.1 增加版本化启动迁移，将 Kokoro 默认模型回退到 Apple 系统语音、清除旧 voice ID，并移除 Kokoro 安装记录与下载断点
- [x] 3.2 在路径校验通过后清理 App 管理目录内的 Kokoro 权重；路径校验失败时保留文件并记录可诊断错误
- [x] 3.3 将绑定 Kokoro 的未完成任务标记为“模型已移除，需要重新开始”，保留书籍/任务元数据并阻止调度器复用旧 checkpoint
- [x] 3.4 将重新开始操作接入既有任务重置流程，确认旧 checkpoint 被清理后才使用当前受支持模型创建新任务快照
- [x] 3.5 运行迁移测试，覆盖重复启动、已完成/已导出任务不受影响、异常目录不误删以及旧模型不会重新出现在目录中

## 4. 删除 Kokoro 与跨架构运行时

- [x] 4.1 删除 `KokoroTTSRuntimeClient`、`KokoroCompatibilityAcceptanceRunner` 及 App 启动参数中的 Kokoro 验收入口
- [x] 4.2 删除 Kokoro 集成/真实 EPUB 验收测试并将仍有价值的通用运行时、取消、音频校验断言迁移到 Apple Speech 或 speech-swift 测试
- [x] 4.3 从 `AudiobookMaker.xcodeproj` 的文件引用、Link Binary、Embed Frameworks、搜索路径和签名阶段移除 `SherpaOnnx.xcframework` 与 `OnnxRuntime.xcframework`
- [x] 4.4 删除仓库中的 Sherpa/ONNX vendor 二进制、Kokoro 专属脚本/模型元数据/验收文档，并通过源码与产物扫描确认没有可执行残留引用

## 5. 配置 Apple Silicon 专用构建与运行边界

- [x] 5.1 将 App、单元测试和 UI 测试 target 的 Debug/Release 架构显式限定为 arm64，移除 Universal 2/x86_64 构建设置和仅服务 Intel/Rosetta 的条件
- [x] 5.2 更新 CI、Archive、签名、公证和 Release 打包命令为 arm64-only，并在签名/发布前强制执行架构与依赖纯净性门禁
- [x] 5.3 简化 `SpeechSwiftPlatformSupport` 及调用方：保留最低 macOS、Metal 和运行时资源检查，在任何失败情况下均于 MLX 初始化和模型下载前返回稳定错误
- [x] 5.4 增加平台探测测试，覆盖受支持原生 arm64、Metal 缺失、系统版本不足和运行时资源损坏，确认失败路径不初始化 MLX

## 6. 优化统一的 MLX 推理路径

- [x] 6.1 profile CosyVoice3 与 Qwen3-TTS 的模型加载、首段生成、连续片段和切换模型路径，依据数据定位重复加载、复制和同步热点
- [x] 6.2 实现相同模型/版本连续片段的已验证会话复用，并在切换模型、不可恢复错误或空闲内存压力时安全释放可重建会话
- [x] 6.3 将实际并发限制为用户配置、运行时建议与模型安全上限中的最小值，并保持 token、KV-cache、生成时长与句子边界切片约束
- [x] 6.4 验证取消中的 Metal 请求停止后续提交且丢弃晚到结果，确保不会提交取消后的 checkpoint 或触发 GPU watchdog 风险
- [x] 6.5 添加会话复用、内存压力卸载、并发上限、长文本切片和取消竞态测试，并运行 speech-swift 模型选择与离线合成验收

## 7. 文档、供应链与最终验收

- [x] 7.1 更新 `README.md`、开发/运行时分发说明和系统要求，明确仅支持 Apple Silicon、移除 Kokoro/Intel/Universal 2，并更新构建与下载步骤
- [x] 7.2 更新第三方声明、SBOM、隐私/联网说明和 Release notes，移除 sherpa-onnx、ONNX Runtime、Kokoro 条目并保留 speech-swift/MLX/模型许可信息
- [ ] 7.3 在干净 Apple Silicon 环境执行全量单元/UI 测试及模型下载、取消恢复、离线试听、转换暂停恢复、M4B 导出和损坏模型重装验收
- [ ] 7.4 生成签名公证的候选 archive，执行 arm64-only 与依赖纯净性门禁，并核对 App bundle 不含模型权重或已移除 runtime
- [ ] 7.5 在固定基准环境运行冷/热性能套件，与批准基线比较并处理超门限回归；保存可追溯结果后确认发布就绪
- [ ] 7.6 确认 major version、最后一个 Universal 2 版本的保留策略和用户迁移公告，并将决定写入发布文档