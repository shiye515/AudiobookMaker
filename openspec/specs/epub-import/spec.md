## Purpose

EPUB 导入：把 .epub 电子书文件解压并解析为标准书籍项目（封面图、元数据、章节目录与清洗正文），入库书架。

## Requirements

### Requirement: 导入入口

用户 SHALL 能通过工具栏「+ 导入 EPUB」按钮（⌘N）唤起系统文件面板选择 .epub 文件，且能将 .epub 文件拖入主窗口完成导入。一次 SHALL 支持选择多个文件批量导入。

#### Scenario: 文件面板导入

- **WHEN** 用户点击「+ 导入 EPUB」并选择一个或多个 .epub 文件
- **THEN** 文件被解析入库，书架出现对应图书卡片

#### Scenario: 拖拽导入

- **WHEN** 用户将 .epub 文件拖入主窗口
- **THEN** 该文件被解析入库，效果与面板导入一致

### Requirement: EPUB 解析

导入时系统 SHALL 解压 EPUB 容器并提取：封面图（cover 图像，无封面时用生成的占位图）、书名与作者（OPF 元数据，缺省时用文件名）、章节目录（nav.xhtml 或 toc.ncx，缺失时按 spine 顺序推导）与各章正文纯文本（剥离 HTML 标签、合并空白、统计字数）。解析 SHALL 在后台执行并反馈进度，不阻塞界面。

#### Scenario: 解析标准 EPUB

- **WHEN** 导入一本含封面、目录与正文的 EPUB
- **THEN** 书架卡片展示封面、书名、作者与总字数，书籍包含与目录一致的章节列表及各章字数

#### Scenario: 缺失目录的 EPUB

- **WHEN** 导入一本缺少 nav/ncx 目录的 EPUB
- **THEN** 按 spine 顺序生成章节列表，导入不失败

### Requirement: 重复导入处理

对同一 EPUB 的重复导入（同一文件内容标识）SHALL 在书架中提示已存在，不产生重复条目；用户可选择重新导入覆盖。

#### Scenario: 重复导入提示

- **WHEN** 导入一本已在书架中的 EPUB
- **THEN** 界面提示该书已存在，书架不出现重复卡片
