## ADDED Requirements

### Requirement: 书籍处理保持在本机
系统 SHALL 在本机完成 EPUB 解析、章节文本处理、TTS 请求、媒体封装和 ZIP 导出，MUST NOT 将书籍内容、章节正文或音频上传到云端。

#### Scenario: 完整转换一本书
- **WHEN** 用户导入并转换一本 EPUB
- **THEN** 所有正文与音频数据只在 App 容器和本地运行时之间流动

### Requirement: 外部文件权限最小化
系统 SHALL 启用 App Sandbox，只在用户选择的导入或导出操作期间访问 security-scoped URL，并 SHALL 在导入后使用 App 管理副本。

#### Scenario: 导入复制完成
- **WHEN** 外部 EPUB 已成功复制到 App 容器
- **THEN** 系统结束对原始 security-scoped URL 的访问且后续处理使用内部副本

#### Scenario: 导出目录书签
- **WHEN** 用户明确选择保存导出目录
- **THEN** 系统只保存该选择所需的安全书签，不扩大访问范围

### Requirement: ZIP 解包防止不受信任输入攻击
系统 MUST 拒绝绝对路径、父目录逃逸、符号链接、无效 CRC、加密条目、不支持的压缩方法、超过限制的单文件/总展开大小和异常压缩比。

#### Scenario: EPUB 包含路径逃逸条目
- **WHEN** ZIP 条目路径解析后位于导入临时目录之外
- **THEN** 系统终止导入、清理临时内容并报告 unsafeArchive

#### Scenario: EPUB 疑似压缩炸弹
- **WHEN** 文件数量、展开大小或压缩比超过安全阈值
- **THEN** 系统在继续展开前停止导入并报告安全限制

### Requirement: 运行时边界受验证和限制
系统 SHALL 校验 XPC 服务身份、协议版本、允许调用的方法、输入大小和可访问文件位置，并 MUST 拒绝不符合契约的请求或响应。

#### Scenario: 运行时返回容器外路径
- **WHEN** XPC 响应引用不在允许共享位置的文件
- **THEN** 系统拒绝该响应且不读取目标文件

### Requirement: 日志不泄露书籍内容
系统 MUST NOT 在 OSLog、错误遥测或开发日志中记录章节正文；书名、作者和绝对路径 SHALL 使用隐私标记或稳定标识替代。

#### Scenario: 合成请求失败
- **WHEN** 运行时返回错误
- **THEN** 系统日志只记录 request ID、阶段、耗时和稳定错误码，不记录请求文本

### Requirement: 删除边界对用户透明
系统 SHALL 在删除确认中说明只清理 App 管理的数据，并 SHALL 在删除后清理相关正文、临时文件和音频，但 MUST NOT 声称在 APFS/SSD 上完成物理安全擦除。

#### Scenario: 删除完成
- **WHEN** 用户确认并完成书籍删除
- **THEN** App 管理目录中不再保留该书的可访问正文或音频，原始 EPUB 保持不变
