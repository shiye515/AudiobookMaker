## Context

章节拆分现状与根因（探索结论，详见对话）：①章节单位 = spine 文档（`EPUBParser.swift:165`）；②`navigationTitleMap`（:204）把 nav/ncx 拍平为 `[路径→标题]`，层级与同路径多锚点互相覆盖；③`resolvedArchivePath`（:238）丢弃 fragment。正文抽取由 `XHTMLTextDelegate` 完成，但只产出整文档纯文本，无锚点位置信息。

两处已验证的前提：①导出的 FFMETADATA 章节表从 `Chapter.title` 生成——改用 `fullTitle` 后导出自动携带层级；②无目录 EPUB 走 spine 文档拆分的现状分支需保留（`epub-import` 主规格已有该场景）。

用户已拍板：方案 A（全局默认按节拆，无配置项）；层级全展开不折叠；结构化存储 `parentPath` 并放弃历史兼容。

## Goals / Non-Goals

**Goals:**

- 目录树形解析（nav/ncx）：navpoint 嵌套、父标题链、fragment 全保留；nav 只取 toc 区段。
- 锚点切分：`XHTMLTextDelegate` 增量记录带 `id` 元素的正文偏移，目录锚点映射为字符区间。
- 标题全展开：`Chapter.parentPath` 存祖先链、`title` 存叶子标题，派生 `fullTitle`。
- 防御性回退：锚点缺失并入上一区间；空正文叶子跳过；无目录退化 spine 拆分。
- 模式断档可见：旧书解码失败时用户可感知、可恢复（重新导入）。

**Non-Goals:**

- 不做拆分粒度配置项（方案 A：全局默认按节拆）。
- 不做旧书自动迁移（模式变更后存量书解码失效，重新导入即得新拆分；用户已授权放弃历史兼容）。
- 不改导出流程结构（仅章节名来源切换为 `fullTitle`）、不改章节表格结构（仅展示文本切换）。
- 不做章节树形化（`Chapter.children`）与独立目录表——层级用祖先数组表达，保持合成单元线性。

## Decisions

### D1. 目录树：`NavigationDocumentDelegate` 产出 `TOCNode` 树

nav.xhtml 与 toc.ncx 各自解析为 `TOCNode { title, fragment: String?, children: [TOCNode] }`。层级链在消费侧沿父链拼接。

- **nav 只解析 `epub:type="toc"` 的 `<nav>` 区段**：page-list、landmarks 等不得入树，否则会变成假层级/垃圾章节。ncx 的 navPoint 本身即目录，无需过滤。
- **来源优先级确定**：nav 树非空则整棵采用；否则采用 ncx 树。**不做两树按条目深合并**（`manifest.values` 遍历序不稳定，混写会导致标题覆盖不确定）。
- **去重**：同一 `(文档路径, fragment)` 在目录中出现多次时保留首次标题。
- ncx 的 navpoint 嵌套与 nav 的嵌套列表均按嵌套深度建树。

*备选*：维持平字典 + 约定键编码层级——把结构塞进字符串键，解析消费两端都要反推，放弃。

### D2. 叶子展开与切分计划（SplitPlan）在解析器内完成

解析器遍历树收集叶子（含祖先链），按"叶子目标文件 + fragment"分组，产出每个 spine 文档的切分计划 `[(fragment, 叶子标题, parentPath)]`；无叶子的文档沿用现状单章。切分计划的消费点在文档文本抽取后：区间 = 相邻锚点偏移之间。

**回退章的 parentPath**：无叶子文档若目录中有条目指向该文件，取该条目的标题为 `title`、其祖先链为 `parentPath`；无任何目录条目时 `title` 回退 `documentTitle` / `第 N 章`，`parentPath = []`。

*备选*：解析器只产树、切分逻辑放 EPUBImportService——切分强依赖正文偏移信息，留在解析器内聚，放弃。

### D3. 锚点偏移：`XHTMLTextDelegate` **增量**记录 `id → 正文字符位置`

`didStartElement` 时若元素带 `id` 属性，且 `ignoredDepth == 0 && inBody`（块级换行插入之后），将 **当前增量计数器值** 记为该锚点偏移。

⚠️ **禁止在记录点调用 `buffer.count`**：Swift `String.count` 为 O(n)，逐锚点调用在大书单文件场景是 O(n×锚点数)。委托内在 `foundCharacters` / 追加换行时同步维护 `characterCount`（`+= string.count`），记录时只读计数器。

同一 `id` 在文档中出现多次时取**首次**出现的偏移。目录锚点经 `resolvedArchivePath`（保留 fragment）映射为 `(文件, 锚点)`，切分点即锚点偏移排序后的区间边界。

*备选*：DOM 解析（XMLDocument）——现管线为 SAX 委托式且内存友好，引入 DOM 重构面大，放弃。

### D4. 偏移与 normalizedText 的一致性约束（关键实现细节）

`normalizedText` 对 buffer 做三次正则后处理（空白合并、去行尾空格、压缩空行），会改变字符位置——**锚点偏移必须基于原始 buffer，切分后再规范化**。实现取「区间独立 normalize」：按原始偏移切 raw buffer，每个区间各自跑与 `normalizedText` 相同的正则链，避免位置映射复杂度；验收场景覆盖"切分点前后无多余空白"。

### D5. 层级结构化存储：`Chapter.parentPath` + 叶子 `title`，`fullTitle` 为派生值

`Chapter` 新增 `parentPath: [String]`（祖先标题链，根在前；章级/回退章按 D2 规则填充），`title` 只存叶子标题；新增计算属性 `fullTitle = (parentPath + [title]).joined(separator: " · ")`。

**消费规则（实现时逐项切换，禁止只改表格）：**

| 消费点 | 使用 |
|---|---|
| 章节表格展示（`ChapterQueueTable`） | `fullTitle` |
| M4B FFMETADATA 章节表（`chapters.map(\.fullTitle)`） | `fullTitle` |
| 分章 m4a/WAV 文件名（`safeFileName(fullTitle)`，已有 `NNN-` 前缀） | `fullTitle`（叶子名「第一节」会撞名） |
| 分章 AVMetadataItem title | `fullTitle` |
| 导出/合成日志、`ExportError.missingAudio` | `fullTitle`（便于定位） |
| 播放条 `player.play(title:)` | **叶子 `title`**（播放条更干净，副标题已是书名） |

选结构化而非标题拼接的理由：信息无损（` · ` 反解不可靠）、展示可分级（叶子/全路径）、解锁按卷/章批量操作（如按 `parentPath.first` 换音色）、未来按卷分文件导出有结构支撑。M4B 章节结构本身为扁平格式，层级以 `fullTitle` 文本呈现（格式上限，非实现缺陷）。

*备选*：标题拼接零模型改动——信息有损、无法分组筛选，用户已授权放弃历史兼容，放弃。

### D6. 模式变更、存量断档与用户可见性

`Chapter.parentPath` 以非可选数组写入新 book.json；旧 book.json 缺该键，合成 `Codable` 解码失败（默认值不会作用于合成解码，预期行为）。

- `LibraryStore.loadAll` 解码失败时**收集失败 bookID**（不再只打日志后静默 `continue` 无上层感知），由 AppStore 暴露给书库 UI。
- **用户可见提示（必须）**：书架出现横幅或空态说明「有 N 本书因章节结构升级无法加载，请重新导入原 EPUB」；可附失败书目录名/ID 便于对照。授权放弃的是数据兼容，不是无提示消失。
- 存量书恢复方式 = 重新导入同一 EPUB（bookID 为文件指纹，同文件覆盖流程既有）；音频需重新合成。磁盘旧目录在重导覆盖前保留，不主动删除。
- 不做自动迁移脚本（数据可再生，迁移脚本是一次性复杂度）。

*备选*：自定义解码给默认值 `[]` 实现静默兼容——旧书会呈现为"章级标题"但内容仍是文档级拆分，与节级拆分语义混淆，放弃。

### D7. 防御性回退（规格场景对应实现）

- 叶子锚点在文档内无对应偏移：并入上一区间（该文档首叶子缺失则下界为文档开头）；
- 区间文本 normalize 后为空：跳过该叶子（与现状"空文本跳过"一致）；
- 叶子指向的文档不在 spine 或不可读：跳过；
- 文档有正文但无任何目录叶子指向：整文档单章（标题与 parentPath 回退链见 D2）；
- 无目录：现状 spine 分支不动，各章 `parentPath = []`；
- **父节点带 fragment 且有子节时**：父锚点不作为切分点（规格单位=叶子）；`#父 → #首子` 的正文并入首子节。这不是丢段，是归属选择，实现时不要擅自把中间节点拆成独立章。

## Risks / Trade-offs

- [锚点偏移在嵌套/hidden 元素下的边界（hidden 内的 id 不应产生偏移记录）] → 偏移记录仅在 `ignoredDepth == 0 && inBody` 时进行，与正文收集条件一致。
- [章节数量增长使章节表格与队列条目膨胀] → 机制通用、总合成时长不变；用户已知情选择全拆（方案 A）。
- [制作粗糙 EPUB 的目录与正文错位] → 已定义回退（锚点缺失/空区间/无目录/父节点归属），最坏退化为现状行为。
- [同文件锚点切分后各章字数统计] → 区间独立 normalize 后按字符计数，与现状统计口径一致。
- [旧书从书架消失引发「数据被删」误解] → D6 强制用户可见提示；旧目录不主动删除。
- [`buffer.count` 误用导致大书解析退化] → D3 强制增量计数，code review 对照项。

## Migration Plan

**book.json 模式变更（Chapter 新增 `parentPath`），存量书籍解码失败将从书架列表移出——需重新导入 EPUB 恢复（bookID 不变，覆盖既有目录；音频重新合成）**。用户已授权放弃历史兼容；同时必须提供可见提示（D6）。无自动迁移脚本（数据可再生，脚本是一次性复杂度）。回滚实现即恢复旧解析，但新模式 book.json 在旧代码下同样解码失败——回滚同样需重导，双向对称。

## Open Questions

（无。粒度、层级展开、结构化存储与放弃历史兼容已由用户决策；其余按上述默认。）
