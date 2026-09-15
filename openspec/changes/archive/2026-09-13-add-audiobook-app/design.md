## Context

MVP 已交付：TTSEngine actor 适配层（本地 bf16 权重、串行合成、长文本 TextChunker 分段）、10 款内置音色库（打包 mp3 + JSON）、WAV 唯一命名原子落盘、run ID 全链路日志、icns 图标链路。设计规范 `docs/EPUB-AUDIOBOOK-UI-DESIGN.md` + `docs/ui-mockups/`（00–04 五张稿）定义了 5 个界面的布局、组件与交互。本 change 把单文本 MVP 升级为完整有声书应用。

## Goals / Non-Goals

**Goals:**

- 按设计稿实现 5 个界面与 NavigationSplitView 骨架，工程结构与设计文档 §4 一致
- 真实功能闭环：EPUB 解析入库 → 章节批量合成（复用现有引擎）→ 试听 → M4B/MP3/WAV 导出
- 书籍项目持久化，重启恢复书架与章节状态
- 保留 MVP 全部行为（快速单文本视图、日志、目录按钮）

**Non-Goals:**

- 用户导入自定义音色（范围已砍，维持）
- 并发多实例合成（单引擎串行，见已调研结论）
- 阅读器/排版界面、音频编辑、云同步、TTS 参数暴露（nTimesteps 等）
- DRM 保护的 EPUB（不支持解密，导入时报错提示）
- 导出格式之外的分享集成（AirDrop 等系统自带能力不集成）

## Decisions

1. **EPUB 解压用 ZIPFoundation**（新 SPM 依赖，MIT，社区标准）：EPUB 是 zip 容器，Foundation 无内建解压；自写 inflate 不值当。解析流程：读 `META-INF/container.xml` → OPF 路径 → metadata（dc:title/creator）→ spine + manifest → 目录优先 nav.xhtml、回退 toc.ncx、再回退 spine 推导 → 逐章 HTML 剥标签（正则 + 实体解码）清洗统计。文件内容标识（大小 + 修改时间的哈希）用于重复导入判断。
2. **书籍项目持久化为目录约定**：`~/Library/Application Support/abm/library/<bookID>/`（bookID = 内容哈希前 16 位），内含 `book.json`（清单：元数据、章节数组含状态/音色/时长/文件名）、`cover.jpg`、`audio/ch<序号>.wav`。启动时扫描 library 目录重建书架（清单为唯一事实来源，音频文件缺失的章节自动回退等待态——天然断点保护）。
3. **批量队列 = 现有 TTSEngine 之上的调度 actor（BatchQueueManager）**：持有待处理章节队列与暂停标志；逐章调 `engine.synthesize`（引擎内部已有长文本分段），每章完成即落盘回写清单；暂停在段间生效（复用引擎分段粒度）。**不改引擎协议语义**，只在其上排队——保证 MLX 线程安全约束不被破坏。
4. **M4B 导出走 AVFoundation 组合**：`AVMutableComposition` 拼接章节音频 + `AVTimedMetadataGroup`（quickTime 章节元数据）写章节标记 + `AVAssetExportSession`（AAC）出 `.m4b`；封面与书名/作者作为 AVMutableMetadataItem 注入。MP3 用 AVAssetExportSession 逐章转码 + ID3 由 AVFoundation 元数据承担；WAV 直接复制章节文件。风险点在 Apple Books 对章节 atom 的兼容性，验收时实测。
5. **波形渲染用 SwiftUI Canvas + 采样降采样**：从 WAV 读取 [Float]（复用引擎的解码函数），按像素列取峰值绘制竖条；播放进度用两层绘制（灰底 + 高亮已播）。试听样本 mp3（音色中心）与章节 wav（播放器）共用一个 `AudioPlaybackService`（AVAudioPlayer 封装，单实例互斥，天然满足"新试听打断旧试听"）。
6. **遥测**：RTF 取引擎近期合成滚动均值（引擎已在 SynthesisOutput 返回各阶段耗时）；内存用现有 `phys_footprint` 读取；ETA = 剩余字数 / 近期吞吐。
7. **状态层**：`AppStore`（@MainActor @Observable 单例）持有书籍字典、导航路由、引擎状态机引用；视图全部从 Store 派生，避免多份 @State 撕裂。BatchQueueManager 为独立 actor，通过 AsyncStream/回调把进度事件送回 Store。

## Risks / Trade-offs

- [EPUB 结构千奇百怪（无目录/嵌套标签/实体编码）] → 三级目录回退 + 宽松清洗 + 解析失败单章跳过并日志记录；不支持 DRM 在导入错误中明示
- [M4B 章节标记兼容性] → 验收实测 Apple Books/播客；不达标则回退方案为 MP3 分章 + 文件名序号（已列为正式格式）
- [长书（百万字）生成耗时数小时] → 断点续生成（清单持久化 + 暂停/恢复）、逐章落盘可试听，用户可分批生成；性能优化（量化权重）另行立项
- [ZIPFoundation 新依赖] → MIT、无传递依赖、仅用于导入；锁版本 tag
- [同步组仍不编译 asset catalog] → 音色中心头像用代码绘制/内置 PNG 散文件（走已验证的 Resources 机制），不依赖 xcassets 新增条目

## Migration Plan

纯增量：新增 Models/Services/Views 目录与依赖；`ContentView.swift` 改造为 QuickTTSView（控件不换血），`abmApp` 挂 Store 与快捷键。无数据迁移。回滚 = revert 单一 commit。

## Open Questions

（无——交互与视觉以设计稿为准，存疑处按 HIG 惯例就近处理并在实现中记录）
