## 1. 目录树解析（EPUBParser.swift）

- [x] 1.1 新增 `TOCNode` 与 `NavigationDocumentDelegate` 树形化：nav 只解析 `epub:type="toc"`；ncx navpoint 嵌套；nav 树非空整棵采用否则 ncx。验证：`pagelist_nav.epub` 夹具（landmarks/page-list 不入树）
- [x] 1.2 `resolvedArchivePathAndFragment` 保留 fragment；原 `resolvedArchivePath` 委托后丢弃 fragment
- [x] 1.3 叶子收集：`(路径, fragment, 叶子标题, parentPath)`，去重保留首次。验证：`nav_toc_split.epub` 层级链全展开

## 2. 锚点切分与模型

- [x] 2.1 `XHTMLTextDelegate` 增量 `characterCount` 记录锚点；重复 id 取首次；仅正文可见区
- [x] 2.2 按锚点偏移切 raw buffer、区间独立 normalize；缺失并入上一区间；空区间跳过；无叶子整文档单章；父节点不切分
- [x] 2.3 `Chapter.parentPath` + 派生 `fullTitle`；消费点已切换（表格/导出/日志用 fullTitle，播放条用叶子 title）；`xcodebuild` 通过
- [x] 2.4 `loadAll` 返回 `failedBookIDs`；书库横幅提示重新导入；重导后移除失败项

## 3. 防御与回归

- [x] 3.1 夹具覆盖：锚点缺失（`missing_anchor.epub`）、无目录退化（`no_toc.epub`）、page-list 过滤、同文件锚点切分。运行：`scripts/verify_epub_split.sh`
- [ ] 3.2 真实书回归：重新导入既有 EPUB，对比章节数与层级链（需用户本机书库）
- [ ] 3.3 端到端 M4B 导出：Apple Books 章节列表带层级链（需用户本机验证）
- [x] 3.4 HANDOFF 第 15 节已记录

## 验证方式说明

已采用方案 2：`scripts/make_epub_fixtures.py` 构造迷你 EPUB → `abm --verify-epub-split` 断言章节数/标题链。入口亦见 `scripts/verify_epub_split.sh`。
