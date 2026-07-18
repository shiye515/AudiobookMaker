# AudiobookMaker 发布验收报告

日期：2026-07-18  
环境：macOS 26.5.2（x86_64 MacBook Pro）、Xcode 26 工具链  
真实样本：`/Users/shiye/Downloads/李光耀论中国与世界_李光耀.epub`

## 结论

本次 OpenSpec `build-audiobook-maker` 的实现任务已全部完成。Release App 已构建、签名校验通过并可直接启动。应用主体使用 SwiftUI、AppKit、SwiftData、Foundation、Compression、CryptoKit、ImageIO、AVFoundation、Core Media、OSLog 和 NSXPCConnection，不包含第三方运行库。

生产转换路径使用 Apple `AVSpeechSynthesizer`。确定性 mock 仅用于自动化测试；RealReader 中的 CosyVoice/MLX 目录与运行时契约已经保留为可替换边界，但当前这台 Intel Mac 不具备 MLX/CosyVoice 的本机运行条件。

## 全量自动化测试

结果包：`build/FullTest.xcresult`

- 73 项测试通过
- 0 项失败
- 0 项跳过
- 覆盖 Swift Testing、XCTest、XCUITest
- 包含 EPUB 安全解析、SwiftData、队列/暂停/恢复、系统语音、XPC DTO、M4B、ZIP64、导出、安全、隐私、本地化、VoiceOver、键盘和外观测试
- 端到端 UI 测试实际执行 EPUB → 章节 → 队列 → M4B → ZIP，不使用预览书籍代替业务流程

Xcode 输出中的 `DebuggerLLDB.DebuggerVersionStore.StoreError` 是 Xcode 读取调试器版本快照的环境诊断；测试结果包没有对应测试失败，应用控制台未出现此前的 `layoutSubtreeIfNeeded` HTML importer 问题。

## 真实 EPUB 验收

输入文件 SHA-256：

`409fe0568d197bd01e2e7984a173b62f0ec2d12b5cb281f7ee77099b648c697f`

验收结果：

- 标题：论中国与世界
- 作者：李光耀
- 语言：zh-CN
- 章节数：14
- 14 个章节全部生成并通过 M4B 回读校验
- ZIP 中包含 14 个 M4B、封面、`metadata.json` 和 `README.txt`
- 转换前后原 EPUB 哈希一致
- 测试期间峰值常驻内存：186,363,904 bytes（约 177.7 MiB）
- RecoveryCoordinator 的数据库提交前中断、partial/final 产物与显式继续场景均通过
- `unzip -t`：无错误
- Finder/Archive Utility 同路径的 `ditto -x -k`：成功

保留产物：

- `build/acceptance/李光耀论中国与世界-14章验收.zip`
- `build/acceptance/extracted/`
- `build/full-attachments/真实 EPUB 内存与完整性验收`对应的导出附件

## Apple 播放器验收

抽查文件：`0002-重要人物如何评价.m4b`

- `afinfo`：M4A/M4B 容器、AAC、单声道、44.1 kHz、3.0 秒，可读取 132 个音频包
- QuickTime Player：成功打开；AppleScript 返回文档时长 3.0 秒
- QuickTime Player：实际执行播放后，播放位置由 0 前进到 0.70981253 秒，再暂停
- Apple Books：成功接受该 M4B 打开请求并启动
- AVFoundation 自动化回读额外验证音频轨、时长、元数据、章节项和全文文本轨

当前测试用 mock 音频较短，适合结构与兼容性验收；生产 App 使用 Apple 系统语音生成实际章节音频。

## Instruments 与主线程

保留轨迹：

- `build/AudiobookMaker-TimeProfiler.trace`
- `build/AudiobookMaker-Logging.trace`
- `build/AudiobookMaker-potential-hangs.xml`
- `build/AudiobookMaker-hang-risks.xml`
- `build/AudiobookMaker-Logging-signpost-intervals.xml`

结果：

- Time Profiler 的 potential-hangs 表为零行
- Time Profiler 的 hang-risks 表为零行
- EPUB Import signpost：33.07 ms，后台线程
- Book Conversion signpost：184.18 ms，后台 actor/Core Media 工作线程
- Book Export signpost：17.41 ms，后台线程
- Core Media 音频压缩与 QuickTime movie writer 均显示专用非主线程
- 导入和导出显式使用 utility 优先级的 detached task；封面降采样使用 utility detached task；XPC 使用异步 continuation，没有同步等待

## 可交付应用

Release App：`build/AudiobookMaker.app`

校验：

- `codesign --verify --deep --strict` 通过
- App Sandbox 开启
- User Selected File Read/Write entitlement 开启
- Release 可执行文件约 3.3 MiB
- 使用端到端启动参数完成一次成品 App 启动、导入、转换与导出冒烟测试

