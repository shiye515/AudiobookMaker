## ADDED Requirements

### Requirement: 应用使用自适应三栏信息架构
系统 SHALL 使用原生 `NavigationSplitView` 提供 Sidebar、Content 和 Detail 三栏，Sidebar SHALL 提供书籍和模型一级导航，窗口变窄时 SHALL 按系统行为折叠列。

#### Scenario: 宽窗口浏览书籍
- **WHEN** 窗口宽度足以显示三栏且用户选择书籍导航
- **THEN** 系统同时显示导航、书籍列表和选中书籍详情

#### Scenario: 窄窗口
- **WHEN** 用户将窗口缩小到无法容纳三栏
- **THEN** 系统按 NavigationSplitView 原生规则折叠，而不裁切主要内容

### Requirement: 书籍界面清晰表达所有状态和操作
系统 SHALL 在书籍列表显示封面、标题、作者、章节数、进度和状态，并 SHALL 在详情中根据 ready、queued、converting、paused、interrupted、completed 和 failed 状态提供对应主要操作。

#### Scenario: 转换中的书籍
- **WHEN** 用户选择状态为 converting 的书籍
- **THEN** 详情显示确定或不确定进度、当前章节和“暂停”主要操作

#### Scenario: 已完成书籍
- **WHEN** 用户选择状态为 completed 的书籍
- **THEN** 详情显示“导出有声书…”主要操作和“在 Finder 中显示”次要操作

### Requirement: 系统提供原生搜索、筛选和空态
系统 SHALL 在工具栏提供按书名或作者搜索，在书籍区域提供状态筛选，并 SHALL 在没有书籍时使用系统空态展示导入按钮和拖放入口。

#### Scenario: 搜索书籍
- **WHEN** 用户输入标题或作者关键词
- **THEN** 书籍列表实时显示匹配结果并保留当前筛选范围

#### Scenario: 资料库为空
- **WHEN** 当前没有已导入书籍
- **THEN** 系统显示“尚未导入书籍”、导入按钮和可接受 EPUB 的拖放区域

### Requirement: 主要命令可从菜单和键盘访问
系统 SHALL 在标准 macOS 菜单栏提供导入、搜索、开始/继续、暂停、导出、删除、侧边栏和设置命令，并 SHALL 提供设计文档规定的快捷键。

#### Scenario: 使用快捷键导入
- **WHEN** 用户按下 Command-O
- **THEN** 系统打开原生 EPUB 文件选择器

#### Scenario: 打开设置
- **WHEN** 用户按下 Command-Comma
- **THEN** 系统打开标准 Settings Scene 而不是在工具栏显示自定义设置面板

### Requirement: 界面遵循系统视觉与交互规范
系统 SHALL 使用系统 List/Table、ProgressView、ContentUnavailableView、语义颜色、系统字体、SF Symbols、原生材质和对话框，MUST NOT 以自定义模糊或透明卡片仿制系统 Liquid Glass。

#### Scenario: 深浅色切换
- **WHEN** 系统外观在浅色与深色间切换
- **THEN** 所有文字、状态、分隔线和控件继续使用可读的系统语义样式

#### Scenario: 破坏性操作
- **WHEN** 用户请求删除书籍
- **THEN** 系统使用原生确认并明确说明不会删除原始 EPUB

### Requirement: 状态信息可访问且可本地化
系统 SHALL 支持 VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Transparency 和 Reduce Motion，状态 MUST 由文字或符号表达且不得只依赖颜色；所有用户文案 SHALL 支持简体中文和英文。

#### Scenario: VoiceOver 读取进度
- **WHEN** VoiceOver 焦点进入转换中书籍的进度控件
- **THEN** 系统朗读完成百分比和当前章节的完整语义描述

#### Scenario: 启用 Reduce Motion
- **WHEN** 用户启用 Reduce Motion
- **THEN** 系统减少非必要状态动画且不影响状态理解或任务控制
