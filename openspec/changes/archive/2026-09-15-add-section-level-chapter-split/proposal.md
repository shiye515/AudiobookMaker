## Why

当前 EPUB 章节拆分以 spine 文档（一个 .xhtml 文件）为单位：目录层级被拍平为 `[文件路径 → 标题]`、锚点 fragment 被显式丢弃（EPUBParser.swift 的 `navigationTitleMap` 与 `resolvedArchivePath`），导致同一文件内的多"节"正文被合并为一章，目录里指向 `#锚点` 的节级条目全部丢失。用户需要按电子书目录的最小单位（节）拆分章节，且层级信息在导出时可追溯。

## What Changes

- **目录树保留层级**：`NavigationDocumentDelegate` 从平字典改为树形解析（nav 只取 `epub:type="toc"` 区段、ncx navpoint 嵌套、父标题链、fragment 全保留）；nav 树非空则整棵采用，否则用 ncx，不做条目级混写。
- **正文锚点切分**：`XHTMLTextDelegate` 增量记录每个带 `id` 元素在正文中的字符偏移（禁止逐锚点 `buffer.count`）；目录叶子按锚点偏移把单文件正文切分为多个章节。
- **标题结构化**：`Chapter` 新增 `parentPath: [String]`（祖先链），`title` 存叶子标题；展示与导出统一使用派生的 `fullTitle`（` · ` 连接全路径），**不折叠、不限制层级深度**。
- **拆分策略为全局默认行为（方案 A）**：含目录的 EPUB 一律按目录叶子单位拆分，无配置项；无目录的 EPUB 退化为现状（按 spine 文档拆分）。
- **导出自动带层级**：M4B/分章文件名/分章元数据改用 `fullTitle` 生成；播放条继续用叶子标题。
- **存量书库需重新导入（且用户可见）**：book.json 模式变更，既有书籍解码失效；书架必须提示「N 本书需重新导入」，不允许只写日志。
- **防御性行为**：叶子锚点在正文中找不到对应 `id` 时并入上一区间（首个叶子找不到则从文件开头到下一锚点）；叶子无正文（空文本）跳过；父节点 fragment 正文并入首子节。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `epub-import`: 「EPUB 解析」需求修订——章节拆分单位从 spine 文档升级为目录最小单位（含同文件内锚点切分），章节层级以结构化祖先链保存并以全路径呈现；补充锚点缺失回退、深层级全展开、结构升级后需重新导入的验收场景。

## Impact

- **代码**：
  - `abm/Services/EPUBParser.swift`：NavigationDocumentDelegate 树形化（toc 过滤、确定性优先级）、XHTMLTextDelegate 增量锚点偏移、`ParsedEPUBChapter` 携带叶子标题与 `parentPath`；
  - `abm/Models/BookProject.swift`：`Chapter` 新增 `parentPath: [String]` 与派生 `fullTitle`；
  - `abm/Services/EPUBImportService.swift`：填充 parentPath；
  - `abm/Services/AudiobookExporter.swift`：FFMETADATA、分章文件名、分章元数据、相关日志/错误改用 `fullTitle`；
  - `abm/Views/BookDetail/ChapterQueueTable.swift`：章节名展示改用 `fullTitle`；
  - `abm/Services/LibraryStore.swift` + `abm/Core/AppStore.swift` + 书库 UI：解码失败收集与「需重新导入」可见提示；
  - `abm/Core/AppStore.swift` 播放条仍传叶子 `title`（见 design D5 消费表）。
- **数据影响**：book.json 模式变更，**存量书籍解码失效需重新导入**（用户已授权放弃历史兼容）；音频需重新合成；旧目录在覆盖前保留。
- **行为影响**：重新导入同一本 EPUB 将得到更细的章节列表（bookID 基于文件指纹，同文件重导走覆盖流程）。
- **风险**：锚点切分依赖 EPUB 内部 id 与目录一致——已定义回退；章节数量增多由现有滚动列表承载；旧书「消失」必须有 UI 提示以免被理解为数据丢失。
