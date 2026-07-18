## ADDED Requirements

### Requirement: 用户可以导入 EPUB
系统 SHALL 允许用户通过原生文件选择器或 Finder 拖放导入一个或多个 `UTType.epub` 文件，并 SHALL 对每个文件独立报告导入结果。

#### Scenario: 通过文件选择器导入
- **WHEN** 用户选择一个或多个可读 EPUB 文件
- **THEN** 系统复制文件到 App 管理目录并开始解析每个文件

#### Scenario: 拖入非 EPUB 文件
- **WHEN** 用户将不符合 EPUB 类型的文件拖到导入区域
- **THEN** 系统拒绝该文件且不创建书籍记录

### Requirement: 系统按 EPUB 阅读顺序解析章节
系统 SHALL 从 `container.xml` 定位 OPF，SHALL 以 OPF spine 顺序生成章节，并 SHALL 优先使用 EPUB 3 NAV、回退使用 EPUB 2 NCX 获取章节标题。

#### Scenario: 解析 EPUB 3
- **WHEN** EPUB 包含有效 OPF、spine 和 NAV
- **THEN** 系统按 spine 顺序生成纯文本章节并使用 NAV 标题

#### Scenario: 章节缺少标题
- **WHEN** spine 项没有可用 NAV 或 NCX 标题
- **THEN** 系统按顺序生成本地化的“第 N 章”标题

#### Scenario: 空章节
- **WHEN** spine 项转换后不包含可读文本
- **THEN** 系统跳过该项并记录不含正文的解析警告

### Requirement: 系统提取书籍元数据与封面
系统 SHALL 从 EPUB 提取书名、作者、语言和封面；缺失的非关键元数据 SHALL 使用清晰的系统占位值且不得阻止导入。

#### Scenario: EPUB 包含封面
- **WHEN** EPUB 元数据或 manifest 指向有效图片资源
- **THEN** 系统保存封面并为列表生成降采样缩略图

#### Scenario: EPUB 不含封面
- **WHEN** 系统无法找到或解码封面资源
- **THEN** 系统完成书籍导入并在界面显示系统封面占位图

### Requirement: 导入提交具有事务性
系统 SHALL 在临时目录完成校验和解析后再原子提交书籍目录与 SwiftData 记录，失败导入 MUST NOT 留下可见的半成品书籍。

#### Scenario: 解析中途失败
- **WHEN** EPUB 在解包或 XML 解析阶段失败
- **THEN** 系统清理临时文件、不创建可见书籍，并显示可操作的错误说明

#### Scenario: 重复导入
- **WHEN** 导入文件的 SHA-256 与已有书籍一致
- **THEN** 系统提示用户定位已有书籍或明确创建副本，不静默重复导入

### Requirement: 用户可以浏览书籍与章节
系统 SHALL 展示书籍标题、作者、封面、章节数、状态和总进度，并 SHALL 在选中书籍后按顺序展示章节标题、状态和已知时长。

#### Scenario: 选择书籍
- **WHEN** 用户在书籍列表选择一本已导入书籍
- **THEN** 详情区域展示该书元数据、任务操作、总进度和章节列表

### Requirement: 删除只影响 App 管理的数据
系统 SHALL 在用户确认后删除书籍记录、App 管理的 EPUB 副本、解析文本、临时文件和生成音频，且 MUST NOT 删除用户原始 EPUB。

#### Scenario: 用户确认删除
- **WHEN** 用户确认删除一本书
- **THEN** 系统删除 App 管理的数据并从书籍列表移除记录

#### Scenario: 用户取消删除
- **WHEN** 用户在确认对话框取消删除
- **THEN** 系统保留书籍及全部 App 管理产物不变
