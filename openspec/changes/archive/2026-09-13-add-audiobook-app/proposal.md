## Why

MVP 已验证完整合成链路（本地 CosyVoice3、长文本分段、WAV 落盘与日志），但只能处理"一段粘贴的文本"。产品目标是标准 macOS 有声书工坊：导入 EPUB 整本书、按章节批量生成有声书、书架管理、试听与标准格式导出。`docs/EPUB-AUDIOBOOK-UI-DESIGN.md` 与 `docs/ui-mockups/`（5 张高保真设计稿）已给出完整交互规范，本 change 按其实现。

## What Changes

- **应用外壳**：主窗口重构为 `NavigationSplitView`——左侧边栏（📚 全部图书 / ⏳ 正在生成 / ✅ 已完成 / ⚡️ 快速单文本 / 🎙️ 音色中心）+ 统一工具栏（引擎状态灯、`+ 导入 EPUB` ⌘N、全局搜索）；原 MVP 四控件界面整体保留为「快速单文本」视图
- **EPUB 导入**：`NSOpenPanel` 选择或拖拽 `.epub`，解析封面、书名/作者、章节目录与正文（文本清洗、字数统计），入库到书架
- **书架**：图书卡片网格（封面、书名·作者·字数、生成进度条或状态文案），侧边栏三种筛选语义，全局搜索过滤
- **图书详情**：点击卡片直达——书籍概要卡（封面/元信息/全书默认音色下拉）、遥测卡（RTF、已用时/预估剩余、内存）、活跃章节监控条（分段 i/N、波形动画、暂停/停止/打开音频目录）、章节队列表格（序号/章节/字数/音色/状态/音频时长/试听·重试·删除）
- **批量生成**：`一键生成全书` / `暂停` / `全部停止` / 单章重试与删除重置；章节状态机（等待中/生成中/已完成/失败）；引擎串行队列（actor 隔离，复用现有 TTSEngine），逐章落盘
- **试听**：章节队列表格行内试听按钮直接播放已生成音频（无常驻播放条）
- **导出中心**：模态 Sheet——M4B（带章节标记）/ MP3（分章节 + ID3）/ WAV；嵌入封面元数据；码率选择；输出路径 `~/Music/Audiobooks/[书名]/`；导出进度与完成后访达定位
- **音色中心**：10 款内置音色卡片（分类 Pills、搜索、试听 10s、`设为默认旁白`——作为新书的默认音色）
- **持久化**：书籍项目（清单 JSON + 封面 + 章节音频）存于 `~/Library/Application Support/abm/library/<bookID>/`，重启后书架恢复

## Capabilities

### New Capabilities

- `app-shell`: 应用骨架——NavigationSplitView、侧边栏导航与筛选路由、统一工具栏、快捷键、窗口尺寸
- `epub-import`: EPUB 导入——文件选择与拖拽、封面/元数据/章节目录/正文解析与清洗、重复导入处理
- `book-library`: 书架——图书卡片网格、卡片内容与状态展示、筛选语义、搜索
- `book-detail`: 图书详情——概要卡、默认音色配置、遥测、活跃章节监控、章节队列表格与行内操作（含试听）
- `batch-generation`: 批量生成——全书生成/暂停/停止、章节状态机、串行队列与进度上报、单章重试/删除
- `audiobook-export`: 导出——M4B/MP3/WAV 三格式、元数据嵌入、码率、输出路径、进度与访达定位
- `voice-center`: 音色中心——分类筛选、搜索、卡片试听、设为默认旁白

### Modified Capabilities

- `synthesis-ui`: 界面控件布局需求变更——主窗口升级为侧边栏导航结构，原 MVP 四控件收纳为「快速单文本」视图；视图内控件行为保持不变

## Impact

- **代码**：新增 `abm/Models/`（BookProject/Chapter/ExportPreset）、`abm/Services/`（EPUBParser、BatchQueueManager、AudiobookExporter、PersistenceStore）、`abm/Views/`（MainSplitView、Sidebar、Library、BookDetail、Player、VoiceCenter、QuickTTS）；`ContentView.swift` 迁移为 QuickTTS 视图；`abmApp.swift` 加全局快捷键
- **依赖**：新增 ZIPFoundation（EPUB 解压）；导出用系统 AVFoundation，无新增
- **规格**：主规格新增 8 能力、修改 synthesis-ui；`tts-engine` / `voice-library` 行为不变（被复用）
- **风险面**：EPUB 结构多样性（nav.xhtml vs toc.ncx）、M4B 章节标记兼容性（Apple Books）、长书生成的内存与断点续生成
