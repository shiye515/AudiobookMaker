# 交接文档 — abm: CosyVoice TTS macOS 原生应用

> 交接日期: 2026-09-13
> 来源项目: `/Users/shiye/work/aau`（探索与调研阶段）→ 本项目 `/Users/shiye/work/abm`（实现阶段）
> 当前状态: 技术调研完成、资产就绪、Xcode 工程模板已建，**尚未写任何业务代码**

---

## 1. 一句话项目目标

用 SwiftUI 做一个 macOS 原生 App，通过 CosyVoice3（本地推理，soniqo/speech-swift 框架）把文本转成语音。MVP 界面四个控件：**初始化模型按钮、模型状态、文本输入框、音色选择框**（+ 合成并播放）。

## 2. 已定的技术路线（不要再重新调研）

- **推理框架**: [soniqo/speech-swift](https://github.com/soniqo/speech-swift)（Apache 2.0，1.2k star），SPM 产品 `CosyVoiceTTS`。
  ```swift
  .package(url: "https://github.com/soniqo/speech-swift", branch: "main")
  .product(name: "CosyVoiceTTS", package: "speech-swift")
  ```
  ⚠️ 仓库**没有任何 release/tag**，集成时锁定 commit hash。
- **模型**: Fun-CosyVoice3-0.5B（MLX 量化，零样本克隆式 TTS），三阶段流水线 LLM → DiT 流匹配 → HiFi-GAN，输出 24kHz。
- **性能预期**: 官方标称 M2 Max RTF ≈ 0.5（**未实测**，M0 第一件事就是实测）。
- **音色方案**: 本地模型没有预置音色 ID，音色 = 参考音频（零样本克隆）。音色选择框 = 参考音频库（已备好 10 个）。
- **备选路线**（已调研好、暂不启用）: 百炼云 API `cosyvoice-v3-flash`（WebSocket 协议 + 80+ 音色表，见技术文档附录 A），未来可作第二引擎接入同一 UI（架构上有 `TTSEngine` 协议扩展点）。

## 3. 资产清单（已复制到本仓库）

| 路径 | 内容 |
|---|---|
| `docs/cosyvoice-tts-app.md` | **核心技术文档 v0.2**：架构、状态机、项目结构、里程碑、API 对照、云 API 附录、历史评估。实现前通读 |
| `docs/sample/audiobook_voices.json` | 10 个有声书音色清单：`name`（龙妙/龙三叔…）、`trait`、`audio_file`、`text`（**直接当 referenceTranscript 用**） |
| `docs/sample/*.mp3` | 10 个参考音频（13–32s，128kbps）。`longlaobo_v3.mp3` 31.8s 略超 5–30s 推荐上限，可裁可忽略 |
| `docs/models/CosyVoice3-0.5B-MLX-bf16/` | 主模型权重 2.1GB（含 `speech_tokenizer.safetensors`，克隆必需）。**已被 .gitignore 排除** |
| `docs/models/CamPlusPlus-Speaker-CoreML/` | CAM++ 说话人编码器 CoreML 包 15MB。**已被 .gitignore 排除** |
| `abm/` + `abm.xcodeproj/` | 新建的 SwiftUI macOS App 模板（空白），MVP 从这里开始 |

## 4. 模型加载方式（权重已在本地，跳过下载）

```swift
let model = try await CosyVoiceTTSModel.fromPretrained(
    modelId: "aufklarer/CosyVoice3-0.5B-MLX-bf16",        // 默认 bf16 变体
    cacheDir: URL(fileURLWithPath: "<本地目录>/docs/models/CosyVoice3-0.5B-MLX-bf16"),
    progressHandler: { progress, message in }             // 下载 0→0.5, 加载 0.5→1.0
)
model.warmUp()  // 预编译 MLX 计算图，降低首次合成延迟

let campp = try await CamPlusPlusSpeaker.fromPretrained(
    modelId: "aufklarer/CamPlusPlus-Speaker-CoreML",
    cacheDir: URL(fileURLWithPath: "<本地目录>/docs/models/CamPlusPlus-Speaker-CoreML")
)
```

> App 分发时这两个目录要么打进 Bundle 的 Resources，要么首次启动拷到 Application Support；
> `cacheDir` 指向实际落盘位置。目录内文件齐全时框架不会发起网络请求。

## 5. 合成 API 速查（从源码核实，2026-09-13 版本）

```swift
// 1) 每段参考音频提取一次音色档案（懒加载 + 进程内缓存，见技术文档 3.2）
let tokenizer = /* CosyVoiceWeightLoader.loadSpeechTokenizer(from: bundle 内 speech_tokenizer.safetensors) */
let profile = try model.extractVoiceProfile(
    audio: refSamples,            // 单声道 [Float]，mp3 需自己用 AVAudioFile 解码 + AVAudioConverter 降混
    sampleRate: refRate,
    speechTokenizer: tokenizer,
    camppSpeaker: campp,
    referenceTranscript: json.text  // sample JSON 里的 text 字段
)
// → CosyVoiceVoiceProfile { speakerEmbedding: [Float]?, promptToken/promptFeat: MLXArray?, promptText: String? }

// 2) 合成（完整签名）
let samples: [Float] = model.synthesize(
    text: "要合成的文本",
    language: "chinese",                          // ⚠️ 默认 "english"，中文必须显式传
    instruction: "You are a helpful assistant.",  // 默认值=无风格；传自定义串(如 "Speak cheerfully")才触发 instruct 模式
    speakerEmbedding: profile.speakerEmbedding,   // 四个克隆参数来自 profile
    promptToken: profile.promptToken,
    promptFeat: profile.promptFeat,
    promptText: profile.promptText,
    verbose: true                                 // 打印 LLM/Flow/HiFiGAN 分段耗时，spike 时打开
)
// 返回 [Float] @ 24kHz → 手写 44 字节 WAV header 写临时文件 → AVAudioPlayer 播放（MVP 够用）

// 流式接口存在但【目前是假的】：synthesizeStream 一次性 yield 全部音频（源码注释明说
// "not yet incrementally streaming"），所以 MVP 按整段播放设计，不要建流式管线。
```

## 6. 已知坑清单（实现时逐条对照）

1. `speech-swift` 无 release，**锁 commit hash**；框架调用全部收敛在自建 `TTSEngine` 协议后面（技术文档 4.2），升级只改适配层。
2. `language: "chinese"` 必须显式传（默认 english）。
3. `CosyVoiceTTSModel` **非线程安全**（源码 Warning）——MVP 串行合成即可，并发需每并发一个实例。
4. `synthesizeStream` 未实现真流式，首包时间 = 整段合成时间；UI 的"合成并播放"按钮合成期间要禁用并显示进度/忙碌状态。
5. `extractVoiceProfile` 较慢（跑 S3 tokenizer + flow mel + CAM++ 三段提取），10 个音色**懒加载**：选中才提取，进程内字典缓存。
6. 权重与辅助模型下载已有本地副本，但离线模式参数 `offlineMode: true` 与本地 cacheDir 的配合需在 spike 中验证一次。
7. 首次初始化仍是长任务（加载 2.1GB 权重数十秒），"初始化模型"按钮必须带进度反馈（状态机见技术文档 4.3）。
8. 声音克隆合规：只克隆有权使用的声音，App 内适当提示。

## 7. M0 Spike 结果（2026-09-13，已完成 ✅）

- **出声验证通过**：龙妙音色（零样本克隆）合成 10.7s 中文音频，AVAudioPlayer 播放确认。
- **本机 RTF 实测 ≈ 0.88**（合成墙钟 9.5s / 音频 10.7s）——低于 1.0，**路线继续**，但比官方标称 0.5 慢（此机器非 M2 Max），Release 配置 + 预热后预计还有余量。
- **性能基线**：模型加载冷启动约数十秒（热启动页缓存后 0.9s）；warmUp 0.2s；单音色档案提取 0.73s；峰值内存 phys_footprint ≈ 7.2 GB（MLX 缓存策略所致，长会话需关注）。
- **集成现状**：SPM 依赖已锁 `d655076badd143f99c9ce19642fbea8b643ccc0b`（`kind = revision`，xcodebuild 接受）；spike 代码在 `abm/SpikeRunner.swift` + `abm/ContentView.swift`（窗口自动跑一次，结果落盘 `/tmp/abm_spike_summary.txt`）。
- **spike 中发现的新坑**：
  1. Debug 配置已关 App Sandbox（spike 要直读仓库文件）；M1 决定权重打包/拷贝策略后要重新评估沙箱。
  2. `NSTemporaryDirectory()` 不是 `/tmp`（是 `/var/folders/.../T/`），WAV 落在那里。
  3. stdout 重定向到文件时是块缓冲，进程被杀会丢日志——`log` 已加 `fflush`；框架内部 `print`（含 `verbose: true` 分阶段耗时）仍会丢，需要时改用 os_log 或让它写文件。

## 8. 下一步（按顺序）

1. **M0 spike（已完成，见第 7 节）**
2. **M1 MVP（已完成，见第 9 节）**：OpenSpec change `add-cosyvoice-mvp`（tasks 全勾）
3. **M2 候选项**：音色下拉自动化补验、权重变体切换、错误恢复打磨、流式播放（等框架支持）、WAV 导出
4. git 提示：`abm/.git` 继承自 aau 仓库；新文件目前未跟踪，建议首个 commit 把 `abm/`、`abm.xcodeproj`、`docs/`、`.gitignore`、`openspec/` 一起收进去（`docs/models/` 已被 ignore）。

## 9. M1 MVP 结果（2026-09-13，已完成 ✅）

按 OpenSpec change `openspec/changes/add-cosyvoice-mvp`（proposal/specs×3/design/tasks）实现，14/14 任务完成。

**代码结构**（技术文档 4.5 目标结构的 MVP 裁剪版）：

| 文件 | 职责 |
|---|---|
| `abm/Core/TTSEngine.swift` | 协议 + `VoiceSample` + `EngineError`；UI 不接触框架类型 |
| `abm/Core/SoniqoCosyVoiceEngine.swift` | actor 适配层，唯一框架接触点；懒提取档案字典缓存；串行化 |
| `abm/Core/ModelStateManager.swift` | @Observable 状态机（未初始化/加载中/就绪/出错）+ 合成/播放控制 |
| `abm/Core/VoiceLibrary.swift` | 内置 10 音色（打包 JSON 解码，无用户导入） |
| `abm/Playback/AudioPlayer.swift` | WAV 写出（16-bit PCM/24 kHz）+ AVAudioPlayer 播放/停止 |
| `abm/Core/AppPaths.swift` | 模型/资源路径唯一收敛点（现指仓库目录） |
| `abm/Resources/voices/` | 打包进 target 的 10 个 mp3 + 清单 JSON（拷贝自 docs/sample） |
| `abm/ContentView.swift` | 四控件界面：初始化/状态/音色下拉/文本框/合成/播放-停止 |

**端到端验收记录**（Xcode 辅助功能驱动真实 UI）：启动四控件齐全且未初始化时正确禁用 → 初始化后「就绪」→ 龙妙音色两次合成成功（7.08s 音频/7.77s 墙钟；20.32s 音频/17.39s 墙钟，RTF≈0.86）→ 播放出声（`play()->true` + `didFinishPlaying(success=true)` 客观证实完整播完）→ 空文本点击出现提示。**唯一未自动化验证项**：播放中点「停止」（自动化往返 >20s 抓不住播放窗口；stop 是 AVAudioPlayer 一行调用，用户点击即验）。

**实现中发现**：`@Observable`/SwiftUI 状态渲染正常（hint 即时出现佐证）；`abm/` 是文件同步组，往 `abm/Resources/voices/` 拷文件即自动打包，无需改 pbxproj；`SpikeRunner.swift` 已删除（调用链全部搬入引擎适配层）。

**2026-09-13 用户反馈变更（已完成，tasks 第 6 组）**：①移除播放按钮与 `AudioPlayer.swift`（App 内不播放）；②合成结果 WAV 落盘 `~/Library/Application Support/abm/audio/`（文件名 `时间戳-音色名.wav`），界面显示最近输出文件；③生成细节（音色/字数/时长/耗时/RTF/档案缓存命中/输出路径/错误）追加写 `~/Library/Application Support/abm/logs/abm.log`；界面新增「打开音频目录」「打开日志目录」按钮（NSWorkspace 打开访达）。spec `synthesis-ui` 已改写（播放与停止控制 → 音频输出与目录访问 + 运行日志）。

**2026-09-13 用户反馈变更二（已完成，tasks 第 7 组）**：音频文件"重复/遗漏"排查——已消除的成因：①同秒文件名冲突被静默覆盖（改为 `毫秒时间戳-runID-音色名.wav` 唯一命名）；②非原子写入中断产生残缺文件（改 `Data.write(.atomic)`）。日志大幅加详：每条带 `[pid=N]` + 毫秒时间戳；每次生成有 8 位 run ID 串联全链路（合成开始→参考音频解码→档案提取→模型合成→WAV 落盘→完成/失败，含各阶段耗时与字节数）；应用启动记录 pid（用于识别多实例并发导致的"重复"）。**测试分工：用户负责测试，AI 只负责实现**；测试有问题时把 `~/Library/Application Support/abm/logs/abm.log` 交给 AI 排查。

**2026-09-13 用户反馈变更三（已完成，tasks 第 8 组）**：长文本"遗漏/重复"根因定位——**speech-swift 没有实现上游 CosyVoice 的长文本前端**（上游 `frontend.py text_normalize(split=True)` 按句切分逐段合成再拼接；框架直接整段喂 LLM，超长自回归 + 内存膨胀 + 段尾丢失，对应上游 issue #1654）。修复：新增 `TextChunker`（句末标点切句、短句合并 ~50 字/段、超长句硬切 120 字），引擎分段循环合成、段间 150ms 静音、逐段计时日志 `[seg i/N]`、**空段（0 采样）告警跳过不中断**（此告警出现即说明还有框架侧问题，把日志发来）；UI 显示"合成中…（第 i/N 段）"。spec `tts-engine` 新增长文本分段合成需求。

**应用图标（2026-09-13）**：CoreGraphics 脚本绘制的 1024×1024 主图标（靛紫渐变+声波条）在 `AppIcon.appiconset/AppIcon.png`；生效路径是传统 icns——`abm/Resources/AppIcon.icns`（iconutil 生成，随同步组打包）+ `abm/Info.plist`（`CFBundleIconFile=AppIcon`，与 GENERATE_INFOPLIST_FILE 合并）。注意：**Xcode 26 文件同步组不编译 Assets.xcassets**（actool 不跑），`INFOPLIST_KEY_CFBundleIconFile` 也不被支持——改图标要同步更新 icns。

**排查陷阱备忘**：Xcode 26 Debug 构建的真实代码在 `abm.app/Contents/MacOS/abm.debug.dylib`（58MB），主执行文件 `abm` 只是 59KB 启动壳——`strings` 查主程序判断新旧全都会误判；中文常量与 Swift 小字符串也常不落在 `__cstring`。判断构建版本要看 dylib 或直接跑 UI。

## 8. 环境备注

- 机器: Apple Silicon Mac（macOS 25.6.0 / darwin arm64），框架要求 Apple Silicon + MLX。
- 框架文档: `soniqo.audio/zh/guides/cosyvoice`（CLI 用法）；Swift API 以源码为准（README 里的 `docs/inference/cosyvoice-tts.md` 链接是 404）。
- 关键源码文件（GitHub main 分支）: `Sources/CosyVoiceTTS/CosyVoiceTTS.swift`（synthesize 签名）、`VoiceCloning.swift`（extractVoiceProfile）、`Configuration.swift`、`WeightLoading.swift`、`CamPlusPlusSpeaker.swift`。

## 10. 有声书应用（add-audiobook-app，实现完成待用户验收）

按设计规范 `docs/EPUB-AUDIOBOOK-UI-DESIGN.md` + `docs/ui-mockups/` 实现，OpenSpec change 20/21 任务完成（10.1 端到端验收 = 用户测试）。

**新架构**：`NavigationSplitView` 五视图（书架筛选网格 / 图书详情+章节队列 / 快速单文本 / 音色中心 / 底部常驻播放条），`AppStore`（@MainActor @Observable 单例）承载全部状态；`Models/`（BookProject/Chapter/ExportPreset）+ `Services/`（EPUBParser、EPUBImportService、LibraryStore、AudiobookExporter、AudioPlaybackService、Telemetry）。MVP 四控件界面原样保留为「快速单文本」视图，引擎层（TTSEngine/SoniqoCosyVoiceEngine/TextChunker）未动。

**关键实现**：
- EPUB 解析参考了 `/Users/shiye/work/AudiobookMaker` 的 EPUBParser（用户授权仅解析部分），容器读取改为 ZIPFoundation 垫片（新 SPM 依赖，≥0.9.20）；nav.xhtml/toc.ncx 双目录 + spine 回退、安全路径解析、隐藏元素剥离
- 持久化：`~/Library/Application Support/abm/library/<bookID>/`（book.json 清单 + cover + text/ch<N>.txt + audio/ch<N>.wav）；启动扫描重建书架，生成中/音频缺失章节自动回退等待态（断点保护）
- 批量生成：主线程调度器逐章调引擎（引擎 actor 保证串行），暂停在章节边界生效；注意**「全部停止」不能中断引擎合成中的章节**（同步调用），当前章节会跑完并正常保存，其余清空回等待态
- 导出：M4B = AVMutableComposition 拼接 → 临时 m4a → AVMutableMovie 挂 `quickTimeMetadataChapter`（AVTimedMetadataGroup 数组）+ 封面元数据 → passthrough 出 .m4b；**MP3 不可行**（macOS 无系统 MP3 编码器），分章节格式用 .m4a 替代（spec 已同步修改）；WAV 直接复制
- 音色中心头像走代码绘制渐变（同步组不编译 asset catalog）；默认旁白存 UserDefaults

**新 SDK 坑（macOS 26 SDK）**：`AVMetadataIdentifier` 的 Swift 常量改名 `.commonIdentifierTitle/Artist/Artwork/AlbumName`（不是 `.commonTypeTitle`）；`.quickTimeMetadataChapter` 无 Swift 常量，用 `AVMetadataIdentifier(rawValue: "quickTimeMetadataChapter")`；`AVMutableComposition.metadata` 只读（AVMutableMovie 可写）；`AVMutableMovie` 没有 `insertTimedMetadataGroup`/`export(to:)`。ZIPFoundation 0.9.20 的 `Entry` 是顶层类型。

**待验证（用户）**：真实 EPUB 导入（可用 `/Users/shiye/work/AudiobookMaker/docs/` 里的样例）、批量生成暂停/停止语义、M4B 在 Apple Books 中的章节标记显示、播放器拖拽定位。

**崩溃修复（2026-09-13 晚）**：`Environment+Objects.swift` 强解包崩溃——工具栏内容（`toolbarContent` 访问 `store.route`）在 AppKit NSToolbar 托管/AX 树构建链路下拿不到环境（`.environment(store)` 加在 NavigationSplitView 之上也覆盖不到工具栏托管子树，macOS 26 SDK）。修复：`toolbarContent(isLibrary:)` 参数化，工具栏构建期零环境访问（Binding 闭包保留）。经验：**工具栏/Sheet/菜单等 AppKit 托管的内容不要在构建期直接读 `@Environment` 可选 Observable，用参数传递**。

**模型变体核对（2026-09-13 晚，应用户要求与 soniqo 指南复核）**：指南的量化表格**已过时**——表格称"4bit 默认"，但 pinned 源码里 `fromPretrained` 强校验 config.json 的 `bits ∈ {8,16}`（bits=4 直接抛 modelLoadFailed），CLI 的 `--cosyvoice-variant` 也只有 bf16/8bit/8bit-full，且其他引擎明确标注 "int4 was decommissioned"。最终采用 **aufklarer/CosyVoice3-0.5B-MLX-8bit**（LLM int8 + DiT bf16，repo ~1.4GB + tokenizer ~0.7GB）。其余核对项均一致：CAM++（aufklarer/CamPlusPlus-Speaker-CoreML，~14MB 首用自动下载）、每个 bundle 含零样本克隆所需 S3-Tokenizer、模型 ID 命名规则。教训：**soniqo 指南的量化表格与代码不同步，以源码 + HF 仓库 config.json 为准**。

## 11. 批量生成显存治理（2026-09-13 晚，已实测验证 ✅）

- **问题现象**：长文本大批量连续转换（如单章 283 段）时，物理显存持续飙升至 **17GB**，触发 macOS 系统 Swap 换页，导致部分分段耗时从 ~10s 陡增至 48s（恶化近 5 倍）。
- **根因定位**：
  1. 动态文本长度导致张量 Shape 多变，MLX Metal Caching Allocator 无法就地复用旧 Buffer，各尺寸空闲 Buffer 持续堆积；
  2. Swift 异步 Task 缺少 `autoreleasepool`，底层 CoreML / Metal / Obj-C 包装对象跨循环滞留，阻碍底层物理显存回收；
  3. `speech-swift` 最初针对短交互设计，未在多次生成间主动清空缓存。
- **治理落地**：
  1. **方案 A**：分段合成与音色提取局部包裹 `autoreleasepool`，单段产出后立即排空临时引用；
  2. **方案 B**：引入 `MLX.Memory.clearCache()`，结合 `Telemetry.physFootprintMB()` 实施 `>= 5500 MB` 自适应高水位泄洪 + 每 10 段定期清理 + 退出 `defer` 兜底归零。
- **实测结果**：显存从 17GB 成功收敛并**稳定锁定在 5~6GB 之间**，彻底消除了系统 Swap 停顿，长会话批量转换稳定性达标。


## 12. 悬浮播放条（add-floating-playback-bar，2026-09-13，构建通过，待用户应用内点验）

- **规格**：`openspec/changes/add-floating-playback-bar/`（proposal / specs/playback-bar / design / tasks，四工件齐备，实施期间工件经用户扩充：新增微进度条/时间指示/溯源跳转/防竞态/safeAreaInset 避让）；归档后主规格落在 `openspec/specs/playback-bar/`
- **实现**：
  - `AudioPlaybackService`：改挂 `@Observable` 宏（原手写 conform 的 `Observable` 在本 SDK 是空协议、无观察追踪——**此前 `VoiceLibraryView` 试听按钮状态刷新是靠其它重渲染"碰巧"生效的，本次顺带修复**）；`player`/`ticker` 私有属性标 `@ObservationIgnored`；`play(url:contextID:title:subtitle:bookID:)` 携带播放条展示元数据与溯源 bookID；`stop()` 清空全部；`audioPlayerDidFinishPlaying` 与解码错误回调改为整会话清理（播放条随之隐藏）
  - `PlaybackBarView`（新文件 `abm/Views/Player/`）：显隐绑定 `contextID != nil`（暂停保持可见、停止/播完/异常隐藏）；播放/暂停切换（`togglePause`）+ 停止（`stop`）；主标题 + 副标题 + 微动态波形；底部 2pt 细线进度条（轨道 + 强调色已播段，`currentTime/duration`，ticker 每 200ms 驱动）；`mm:ss / mm:ss` 时间文本；`.ultraThinMaterial` 胶囊（宽度上限 560pt）+ 阴影；弹簧动效 `.spring(response:0.35, dampingFraction:0.8)` + move/opacity 过渡
  - `MainSplitView`：`detailContent` 上 `.safeAreaInset(edge: .bottom)` 挂载——滚动容器自动避让、胶囊居中于 detail 列不横跨侧边栏，覆盖全部五条路由；底部 12pt 浮起边距放在 `PlaybackBarView` 内部与胶囊绑定（空态 inset 严格 0 高、不垫空白）；容器级再挂同频 `.spring(response:0.35, dampingFraction:0.8)` 动画（value: 会话存在性），列表避让伸缩与胶囊浮现/收起完全同步
  - 溯源跳转：章节会话（`currentBookID != nil`）点击名称直达 `store.route = .bookDetail(bookID)`，悬停下划线提示；音色会话静态展示
  - 元数据来源：`AppStore.playChapter` 传（章节名， 书名， bookID）；`VoiceLibraryView` 试听传（音色名， "试听样本"），10s 到点由 `pause()` 改为 `stop()`，且倒计时 `Task` 由 `@State previewTask` 持有、新试听先取消旧 Task + `!Task.isCancelled` 守卫（同卡防竞态），跨卡由 `contextID` 匹配守卫兜底；与 voice-center 规格"最长 10 秒"兼容
- **规格走查（代码级，⑨项全过）**：①试听弹簧浮现 ②暂停保持可见可恢复（`pause()` 保留 `contextID`）③播完/解码异常自动隐藏（delegate → `stop()`）④停止隐藏 ⑤章节名+书名可点击跳转 / 音色名+样本标注 ⑥微进度条 + `mm:ss / mm:ss` 实时（`@Observable` + ticker）⑦连续试听无倒计时竞态（cancel + `Task.isCancelled` + contextID 双守卫）⑧跨路由播放不中断且持续可见（safeAreaInset 在路由 switch 之外）⑨列表末行避让（safeAreaInset 自动安全边距）
- **待用户验证**：应用内真实音频场景（需初始化模型 + 已生成章节音频/音色样本）：弹簧动效观感、进度条/时间走动、点击章节名跳转、波形律动、列表末行避让实际效果

## 13. Release 构建架构坑：Float16 在 x86_64 macOS 不可用（2026-09-13，已修复 ✅）

- **现象**：Debug 调试运行一切正常；Release（Product → Archive / Release 编译）在 `CosyVoiceTTS/CamPlusPlusSpeaker.swift` 报三条错——`'Float16' is unavailable in macOS`、`Argument passed to call that takes no arguments`、`No exact matches in call to initializer`。
- **根因**：三条错误是同一根因的连锁（Float16 类型不可用后，`Float16(melSpec[…])` 与 `Float(embPtr[i])` 的解析全部失效）。`Float16` 在 macOS 仅 **x86_64** 架构不可用；Debug 配置 `ONLY_ACTIVE_ARCH = YES` 只编 arm64 所以正常，Release 默认 `ONLY_ACTIVE_ARCH = NO` 且工程未设 `ARCHS`，回落 `ARCHS_STANDARD`（macOS = arm64 + x86_64 通用二进制），x86_64 切片编译即炸。
- **修复**：`abm.xcodeproj` 项目级与 Target 级的 Debug/Release 四个配置块均显式钉死 `ARCHS = arm64` 并配置 `EXCLUDED_ARCHS = x86_64`（MLX 本身只支持 Apple Silicon，x86_64 切片无意义，防止 SPM 依赖在 Archive 时拉起 x86_64 切片）。已验证：Release 与 Archive 全量构建通过。
- **教训**：引用仅 arm64 可用的 API（Float16/MLX/Metal 相关）时，新建 macOS 工程应第一时间在 Project 和 Target 中钉死 arm64 并排除 x86_64，避免 Archive 阶段才爆雷。


**补充（同日晚）**：修复后 Xcode GUI 仍连续三次按"通用二进制"计划构建（22:56/23:01/23:04，日志显示 x86_64+arm64 各编 ~470 文件），与磁盘工程设置脱节——GUI 在用陈旧的构建计划缓存。CLI 侧强制重编包目标验证：清掉 `DerivedData/…/Build/Intermediates.noindex/Qwen3Speech.build` 后 Release 构建，`CosyVoiceTTS` 纯 arm64 编译通过。**结论：`ARCHS = arm64` 修复本身有效且已传导到 SPM 包目标；GUI 需删除整个 `DerivedData/abm-dxyxwqhnxoxnwhatthxchaxqxuhr` + 重启 Xcode 强制重建计划。**

**Archive 补充（同日深夜）**：进一步发现 **Archive（`generic/platform=macOS` 通用目标）会忽略工程级/目标级的 `ARCHS` 与 `EXCLUDED_ARCHS`**，把 SPM 包目标（CosyVoiceTTS）按双架构编译，x86_64 切片照旧炸 Float16——普通 Build（具体目标）则完全遵循设置，这就是"Build 成功、Archive 失败"的根因（`-showBuildSettings` 在 generic 目标下显示的 ARCHS=arm64 具有误导性，实际构建计划不采用）。**已验证的解法：命令行显式覆盖（优先级最高）**：
```bash
xcodebuild archive -project abm.xcodeproj -scheme abm -configuration Release \
  -destination 'generic/platform=macOS' -archivePath <输出路径>.xcarchive ARCHS=arm64
```
实测 ARCHIVE SUCCEEDED，产物纯 arm64。GUI 的 Product → Archive 会踩同一怪癖，绕过方式即上面这条命令（或将来给 speech-swift 提 patch 让 CamPlusPlusSpeaker 在 x86_64 下编译通过）。

**根治（2026-09-15）：本地化 speech-swift + float32 补丁，GUI Archive 可用**：`Float16` 仅出现在 `CamPlusPlusSpeaker.swift` 的 CoreML `MLMultiArray`（`.float16`）。将 speech-swift 以 `XCLocalSwiftPackageReference` 挂到 `Vendor/speech-swift`（上游 `d655076`），补丁改为 `.float32` + `Float` 指针——全架构可编。实测 **不带 `ARCHS=arm64` 的 archive 也 ARCHIVE SUCCEEDED**，`CosyVoiceTTS` 产出 arm64+x86_64 目标文件；App 本体仍按工程 `ARCHS=arm64` 链接。Xcode 菜单 Product → Archive 可直接用。同步上游见 `Vendor/speech-swift/PATCH.md`。

**内置 ffmpeg 与 Hardened Runtime（2026-09-15）**：上传/校验报 `"ffmpeg" must be rebuilt with support for the Hardened Runtime`。根因：Resources 里嵌套 CLI 仍是 linker adhoc 签名（无 `runtime` 标志），App 本体虽已 `ENABLE_HARDENED_RUNTIME=YES` 但 Xcode 不会自动给 Resources 下的裸二进制补签。修复：①Target 增加 Run Script「Sign Helper Tools」（Resources 之后）用 `EXPANDED_CODE_SIGN_IDENTITY` + `--options runtime` 重签 `Resources/ffmpeg`；②目标关闭 `ENABLE_USER_SCRIPT_SANDBOXING`（否则 codesign 被沙箱 deny）；③`build-ffmpeg.sh` 产出时预置 adhoc+runtime 签名。验证：archive 内 ffmpeg `flags=0x10000(runtime)`，`codesign --verify --deep --strict` 通过。

## 14. 书籍导出"卡在 50%"排查（2026-09-14，已修复进度反馈 ✅）

- **现象**：M4B 导出进度停在 50% 长时间不动。
- **根因**：进度映射为——章节拼接入轨 0→0.6（N 章时最后一步约 0.5 附近），随后**第一遍整书转码**（`AVAssetExportPresetAppleM4A` 重编码全部音频，数小时音频需数分钟到几十分钟）发生在 ~0.5 与 0.7 之间，而 `exportAsynchronously` 回调只在结束时触发一次——转码期间 UI 零反馈，"慢"与"卡死"无法区分。
- **修复**（`AudiobookExporter.swift`）：
  - 新增 `runSession(stage:progressBase:progressSpan:progress:)`：KVO 轮询 `AVAssetExportSession.progress`（500ms），把会话真实进度映射到进度段——拼接转码 0.6–0.85、M4B 章节写回 0.85–0.99、分章节 M4A 每章 1/N 段内填充；每 30 秒输出存活日志（会话进度 % + 已耗时），完成/失败均记日志（含 status、error、输出路径、耗时）。
  - 拼接入轨、WAV 复制逐章日志；导出开始记录章节数与目标目录。
- **验证方式**：重新导出，进度条应在转码阶段从 0.6 缓慢爬到 0.85；日志目录可见 `拼接转码(M4A) 进行中 | 会话进度 X% | 已耗时 Ys`。**若"会话进度"长期停在同一百分比而耗时持续增长，才是真卡死**——把日志发来即可定位到具体阶段。

**追加（同日）**：实测确认 `AVAssetExportSession.progress` 对 `AppleM4A` preset **不产生任何中间值**（KVO 全程 0% → 直接完成），轮询方案无效。已把 M4B 第一遍整书转码从 `AVAssetExportSession` 替换为 **AVAssetReader（逐章 PCM 解码）+ AVAssetWriter（AAC 编码）手工管线**：①进度按已编码秒数/总时长精确计算（映射 0.1–0.85，每 10% 出日志）；②导出设置里的码率 `bitrateKbps` 首次真正生效（`AVEncoderBitRateKey`）；③函数标 `nonisolated`（工程默认 MainActor 隔离，避免阻塞 UI 线程）；④章节时间偏移用 `CMSampleBufferCreateCopyWithNewTiming` 保持，第二遍章节标记写回不变。**待验证：M4B 导出音频完整性与章节对齐**（新管线首次实战）。分章节 M4A 导出仍走 AVAssetExportSession（每章 1/N 粒度够用）。

**修复（同日）**：新管线首跑报 `-11861 Cannot Encode Media`（底层 OSStatus -12651）。探针实测（真实章节 WAV + AVAssetReader/Writer）：**Apple AAC 编码器码率上限与采样率挂钩——24kHz 单声道下 64k 通过、68k/72k/80k/88k/96k/128k 全部被拒**，上限 ≈ 采样率×8/3。原默认 128k 超限近一倍即触发。修复：①`transcodeToM4A` 编码前按 `max(16, sampleRate*8/3000)` 钳制码率并记日志；②默认码率 128→64；③导出面板档位 96/128/192 → 32/64(推荐)。另确认：AVAssetWriterInput 的 AAC 设置**必须显式含 `AVSampleRateKey`**，缺失直接抛 NSException。若将来源音频升到 44.1/48kHz，需重新标定上限。

**M4B 写回卡 85% 根因与方案重构（2026-09-14）**：
1. **根因**：`AVMetadataIdentifier(rawValue: "quickTimeMetadataChapter")` 在 macOS 26 被判定非法（`Bad identifier. Identifier should be of the form "<keySpace>/<key>"`，该 Swift 常量也已从 SDK 移除），异常发生在写回管线内部 → passthrough 会话回调永不触发 → 卡 85%。探针证实改任何字符串形式（含 "quickTimeMetadata/chap"）都无法写章节。
2. **macOS 26 章节机制现状（全部实测）**：`AVMetadataKeySpace.quickTimeMetadata` 实际值已变为 **mdta**；`AVMetadataItem.identifier(forKey:"chap",keySpace:)` 返回 mdta/chap 且导出能完成，但产物**无任何章节结构**（旧键空间 rawValue、mdta、session.metadata 三路探针全零：无 chap 文本轨、无 chpl 盒），且 **passthrough 写回还会丢弃 title/artist/封面元数据**。即 AVFoundation 在 macOS 26 已无法写 M4B 章节。
3. **方案重构（已实现）**：砍掉第二遍写回——第一遍 reader→writer 转码**直接输出 .m4b**（容器与 m4a 相同，扩展名即可），元数据经 `writer.metadata` 写入 itsk/ilst（探针验证 ©nam/©ART 正确落盘、可回读）；进度映射改为：章节扫描 0–10%、整书转码 10–99%（精确到已编码秒数）。`transcodeToM4A` 更名 `transcodeToM4B`，新增 title/artist/coverData 参数。
4. **遗留**：M4B 章节标记暂缺。补齐路径：导出后对文件做 MP4 盒级手术注入 chpl 盒（ffmpeg -map_chapters 等效，需处理 stco/co64 偏移），或跟踪 macOS 26 后续版本恢复 QuickTime 章节机制。分章节 M4A 的 per-file 元数据走 `session.metadata` + AppleM4A 重编码（非 passthrough），不受此 bug 影响，但未逐一复测。

**章节信息补齐（2026-09-14，ffmpeg 注入方案）**：用户反馈导出只有封面无章节。深挖结论：①Apple 兼容章节的真身是 **QuickTime 文本轨 + 音频轨 tref/chap 引用（+ 附加 chpl 盒）**（解剖 ffmpeg 产物实锤）；②**macOS 26 的 AVFoundation 章节读端也坏了**——对 ffmpeg 产的标准章节文件 `chapterMetadataGroups`/`loadChapterMetadataGroups` 一律返回 0（ffprobe 同文件读出 3 章），故应用内无法用 AVFoundation 验证章节；③AVAssetWriter 的 `.text` 直通输入写 m4a 会挂死（多输入喂入死锁），文本轨原生写不可行。**落地方案**：导出末尾用 ffmpeg（`/opt/homebrew/bin/ffmpeg` 或 `/usr/local/bin/ffmpeg`，实测存在）执行 `ffmpeg -i book.m4b -i chapters.txt -map 0 -map_metadata 1 -c copy`（FFMETADATA 毫秒时间基，流复制秒级完成）注入章节，成功后 `replaceItemAt` 原子替换；ffmpeg 缺失时跳过并记日志（不阻塞导出）。进度映射更新：扫描 0–10%、转码 10–94%、注入 94–99%。**待用户验证**：Apple Books 中章节列表显示（AVFoundation 读端已坏，应用内无法自验；ffprobe 已验证格式正确）。**纯原生后续路线**（若要去 ffmpeg 依赖）：MP4 盒级手术——自建文本 trak + tref 注入 moov（moov 在文件末尾，无需修 stco），工作量大。

**ffmpeg 内置化（2026-09-14，构建通过 ✅）**：章节注入不再依赖用户机器的 Homebrew。`scripts/build-ffmpeg.sh` 从源码（ffmpeg 8.1.2 tarball）构建**极简静态 ffmpeg**：`--disable-everything` 只保留 mov/ipod 容器读写 + ffmetadata demuxer + file 协议 + aac_adtstoasc bsf，静态链接（otool 实测仅依赖系统框架 CoreFoundation/CoreVideo/CoreMedia/libSystem），产物 **1.9MB**。端到端验证：与导出器完全相同的注入命令，ffprobe 读回 3 章正常。落位：`abm/Tools/ffmpeg` + `ffmpeg-LICENSE`（LGPLv2.1 许可文本随包分发；此构建未启用 GPL 组件，为 LGPL 路线）→ 同步组自动拷入 `abm.app/Contents/Resources/`（实测落位+可执行位保留+可运行）。`locateFFmpeg()` 查找顺序：Bundle Resources 根 → Resources/Tools → 可执行文件同目录 → Homebrew 兜底。注意：①该二进制为构建产物，已 gitignore，新机器需先跑 `scripts/build-ffmpeg.sh`；②Archive/公证时 Xcode 会对包内嵌套 Mach-O 签名，导出后建议 `codesign -vv` 验证一次；③极简版无编码器（仅流复制），若未来需要转码功能（如 MP3）需扩展 configure。

**优化 backlog**：2026-09-14 全面 review 产出的 13 项优化（性能/测试/架构/打磨，均未实现）见 `docs/OPTIMIZATIONS.md`，动工前按需走 OpenSpec 提案。

**章节注入修复（2026-09-14 晚）**：用户实书导出无章节。日志定位：注入阶段报 `[ipod] dimensions not set`。根因：封面（AVAssetWriter 写为 mjpeg 视频流）在 `-c copy` 时需要探流补全宽高，而极简 ffmpeg 无任何解码器 → codecpar 尺寸 0 → ipod muxer 拒绝（Homebrew 全量版同命令成功，因其有 mjpeg 解码器）。修复：build-ffmpeg.sh 加 `--enable-decoder=mjpeg`（仅探流用，仍零重编码）。实测真实书（14 章）注入成功：章节 + 音频 + 封面流全保留，ffprobe 验证通过。附带认知：ipod muxer 不能直拷既有文本流（"Tag text incompatible"），但会从 FFMETADATA 章节自行合成文本轨——导出器命令无需 `-map 0:a`。

**导出取消 bug 修复（2026-09-14 晚）**：现象：导出 A →"取消"→ 导出 B，结果仍是 A。根因三层：①`runExport` 的 Task 未存句柄，无法取消；②Sheet"取消"按钮只是 `dismiss()`（关窗不停任务）；③导出器全程不检查取消标记——A 继续在后台跑，`isExporting` 仍为 true，B 的 `runExport` 被 `guard !isExporting` **静默拒绝**。修复：①AppStore 持有 `exportTask` 句柄 + 新增 `cancelExport()`（cancel + 立即复位 UI + runID 置空）；②导出器全程协作式取消——章节扫描每章 `Task.checkCancellation()`、M4B 转码循环逐缓冲检查（取消时 `cancelReading`/`cancelWriting` + 删除半成品 outputURL）、ffmpeg 注入前后检查（取消则不替换目标文件）、分章节 M4A/WAV 每章检查并清理已产出文件；③runID 门卫——迟到回调（取消的旧任务完成/失败）不污染新导出的 UI 状态。UI：导出中"取消"按钮变"停止导出"（调 `cancelExport()`，不关 Sheet，显示"已取消导出"），非导出态保持"取消"=关窗。已知取舍：ffmpeg 注入进行中（约 1-4 秒）取消不能中断进程本身，但完成后会丢弃产物不落盘。

**导出重构：整书转码切换内置 ffmpeg（2026-09-14 深夜，refactor-export-ffmpeg-transcode，构建通过 ✅）**：AVAssetWriter 手工管线在长书导出中速度崩塌（80×→1.3×，100% CPU 烧在内部 CMBufferQueue 簿记、编码器线程反而 99% 等待，`sample` 采样实锤）后，整书 M4B 转码重构为**内置 ffmpeg 单命令**：`-f concat`（章节 WAV 列表）+ `-i ffmetadata`（章节表 + title/artist 头部元数据）+ 封面 attached_pic 直拷 + `-c:a aac`。实测同书（8.7h/41 章）**131 秒完成 = 239× 实时**（vs 劣化后管线 6.7h）。进度经 `-progress pipe:1` 解析 `out_time_ms`（单位实为微秒），200ms 节流回报 + 每 10% 里程碑日志；取消经 `withTaskCancellationHandler.onCancel` 即时 `terminate()`（零轮询），半产物清理语义不变；封面参数动态拼接（无封面/未勾选时不得出现 `-map 2:v`）；stdout/stderr `readabilityHandler` 实时消费防 64KB 管道死锁。构建组件新增：concat/wav/image2 解复用器、pcm_s16le 解码、aac/mjpeg 编码、aresample/aformat/anull 滤镜、zlib（png 解码依赖）。**分章节 M4A 与 WAV 路径不变**（AVAssetExportSession/复制）。**待用户应用内回归**：真实书导出速度与产物（Books 章节/封面/听感）、取消即时性。

**补丁（同日）**：首次应用内实跑报 `Failed to open progress URL "pipe:1": Protocol not found`——极简构建漏开 **pipe 协议**（可行性探针当时用文件落盘方式做 `-progress`，未暴露）。修复：build-ffmpeg.sh 加 `--enable-protocol=pipe`，重建后 `-progress pipe:1` 冒烟验证通过（out_time_ms/speed 正常输出）。教训：`--disable-everything` 下**所有协议都需显式开启**，探针命令形态必须与实现逐参数一致。

**补丁 2（同日深夜）**：应用内导出卡 5%（ffmpeg 86 秒零编码输出、无报错、shell 同命令 240× 正常）。stdout 管道 + readabilityHandler 在 GUI 应用上下文存在未解的零输出停滞（进程活着、stdin 假设已被复现实验排除）。**根治**：`-progress` 与 stderr 均改为**写临时文件**由导出循环 250ms 轮询解析（实测 ffmpeg 对 progress 文件实时刷新），完全移除管道与 readabilityHandler 依赖；补 `-nostdin` + stdin 接 /dev/null（子进程卫生）。取消钩子不变（onCancel → terminate）。

## 15. 节级章节拆分（2026-09-15，add-section-level-chapter-split，构建 + 夹具校验通过 ✅）

**改动要点**（`EPUBParser.swift` 为主）：
- 目录树形解析：`NavigationDocumentDelegate` 只收 `epub:type="toc"` 的 nav（排除 landmarks/page-list）；ncx 按 navpoint 嵌套。**nav 树非空则整棵采用，否则 ncx**，禁止条目级混写。
- 叶子切分：无子节点的目录条目才成章；`(路径, fragment)` 去重保留首次；父节点 fragment 正文并入首子节。
- 锚点偏移：`XHTMLTextDelegate` 用**增量 `characterCount`** 记录 `id → 偏移`（禁止 `buffer.count`，O(n²)）；重复 id 取首次；仅 `ignoredDepth==0 && inBody`。
- 切分：按锚点偏移排序切 raw buffer，**区间独立 normalize**（与原整段 normalize 同一正则链）；锚点缺失并入上一区间；空区间跳过。
- 模型：`Chapter.parentPath: [String]` + 叶子 `title`，派生 `fullTitle`。表格/导出文件名/FFMETADATA/日志用 `fullTitle`；播放条用叶子 `title`。
- **模式断档**：旧 book.json 缺 `parentPath` 会解码失败；`LibraryStore.loadAll` 返回 `failedBookIDs`，书库横幅提示重新导入；重导后从失败列表移除。

**回退语义**：无目录 → spine 单章（`parentPath=[]`）；无叶子指向的文档 → 整文档单章（标题/层级取目录中指向该文件的首个条目）。

**校验**：`scripts/make_epub_fixtures.py` + `scripts/verify_epub_split.sh`（或 `abm --verify-epub-split <fixturesDir>`）。夹具覆盖：同文件锚点切分、无目录退化、锚点缺失、page-list 不入树。夹具 XHTML 的 XML 声明必须是 `version="1.0"`（`version="1"` 会让 NSXMLParser 报 error 111）。

**存量书**：升级后需重新导入 EPUB（bookID 为文件指纹，同文件覆盖）；音频需重新合成。

**Calibre 脏目录修复（同日，《李光耀观天下》）**：该书 NCX 大量 src 与正文错位（如 part0019 标成「个人生活」实为「日本：走向平庸」）、多条目共文件且只有 `#calibre_pb_*`。策略调整：①仅当叶子锚点解析出 **≥2 个不同偏移** 才按锚点切分；②整文档章以**正文首行**为可信标题，TOC 标题须与首行/独立行一致才采用（避免「一」被子串误匹配）；③src 错位时按**同名条目**借 `parentPath`；④跳过纯目录页与与全书同名的 `<title>`。夹具回归 ALL PASS。


**性能口径更新（2026-09-16）**：本机当前实测 **RTF ≈ 0.45**（Release 构建 + 预热 + 显存治理后的稳态值），模型页规格卡与相关文档已统一为 0.45。早期记录的 0.88（M0）/0.86（M1）为 Debug 未优化值，作为历史测量保留原文，勿混用口径。
