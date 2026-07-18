## Why

当前项目仍是 Xcode 模板骨架，尚不能完成 EPUB 到有声书的核心流程。需要依据已确认的需求与界面设计，建立一个本地优先、隐私友好、遵循 macOS Human Interface Guidelines 的原生应用，使用户能够可靠地导入、转换、恢复并导出有声书任务。

## What Changes

- 建立 SwiftUI 三栏 macOS 应用框架，提供书籍、模型、章节详情、队列状态、菜单、快捷键和设置界面。
- 使用 SwiftData 建立书籍、章节、TTS 模型、转换任务和应用设置的数据模型，并使用 App 管理的文件目录保存 EPUB、正文和音频产物。
- 支持通过文件选择和拖放导入 EPUB，安全解包并按 OPF spine 与 NAV/NCX 解析章节、纯文本、书籍元数据和封面。
- 定义与具体 TTS 框架隔离的本地运行时契约，支持模型发现、模型加载、能力协商、语音合成、取消和错误回传；首个目标模型为 CosyVoice3 0.5B。
- 实现持久化转换队列、默认单任务并发、暂停/继续、失败重试、异常退出恢复和按章节断点续传。
- 将每章语音封装为包含 AAC 音频、章节项、封面、书籍元数据和整章文本轨的 M4B，并将整本书产物打包为 ZIP 导出。
- 全程采用 Apple 原生应用技术与系统控件，满足 App Sandbox、辅助功能、本地化、性能和隐私要求。
- 在正式功能开发前完成 EPUB ZIP 兼容性、M4B 文本轨/章节轨和 XPC 大音频传递的技术预研。

## Capabilities

### New Capabilities

- `epub-library-management`: EPUB 选择与拖放导入、安全解析、封面和章节管理、书籍删除及 App 内文件生命周期。
- `tts-model-runtime`: TTS 模型目录、默认模型选择、运行时能力协商、模型加载、语音合成与取消的统一契约。
- `conversion-queue-recovery`: 书籍级持久化队列、并发控制、进度、暂停继续、失败重试和异常退出后的断点恢复。
- `m4b-packaging-export`: 章节 M4B 的音频、章节项、封面、元数据、文本轨封装、产物校验及整书 ZIP 导出。
- `macos-native-experience`: 符合 Apple HIG 的三栏界面、工具栏、菜单、快捷键、系统状态反馈、辅助功能和本地化体验。
- `local-data-privacy`: App Sandbox、本地处理、受控文件访问、安全解包、隐私日志和数据删除边界。

### Modified Capabilities

无。项目当前没有既有 OpenSpec capability。

## Impact

- 将替换当前 `ContentView` 与示例 `Item` 数据模型，并重构 App 入口和 SwiftData schema。
- 新增 Library、Book Detail、Models、Queue、Settings 等 SwiftUI feature，以及导入、转换、恢复和导出协调器。
- 新增 Foundation/Compression EPUB 与 ZIP 组件、AVFoundation/Core Media 媒体组件、SwiftData ModelActor 持久化层和 NSXPCConnection 运行时适配层。
- 工程迁移到 Swift 6 严格并发模式，目标平台保持 macOS 26+，并增加 App Sandbox、文档类型、本地化资源与测试 target 配置。
- App 主体不引入第三方 UI、数据库、网络或媒体依赖；CosyVoice/PyTorch 推理实现仍位于本变更定义的运行时边界之外。
