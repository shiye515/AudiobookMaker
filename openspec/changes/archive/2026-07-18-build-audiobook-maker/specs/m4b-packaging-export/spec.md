## ADDED Requirements

### Requirement: 每章生成独立 M4B
系统 SHALL 将每章已验证的 PCM/WAV 片段按顺序合并，使用 AAC-LC 写入 MPEG-4 Audio 容器，并 SHALL 以 `.m4b` 扩展名保存一个章节文件。

#### Scenario: 章节语音合成完成
- **WHEN** 某章所有音频片段均已验证并按顺序就绪
- **THEN** 系统生成一个只对应该章节的临时 M4B

### Requirement: M4B 包含规定元数据和轨道
每个 M4B SHALL 包含可播放音频轨、章节标题、书名、作者、章节序号、封面、t=0 章节项和覆盖整章时长的单个独立文本轨样本。

#### Scenario: 封装包含封面的章节
- **WHEN** 书籍具有有效封面且章节进入封装阶段
- **THEN** 输出 M4B 包含封面、书名、作者、章节标题和章节序号元数据

#### Scenario: 写入整章文本
- **WHEN** 系统写入章节文本轨
- **THEN** 文本轨从 0 开始、持续到音频结束且 UTF-8 正文与章节文本哈希对应

#### Scenario: 无法写入真实文本轨
- **WHEN** Apple 公共媒体 API 无法生成验收播放器可读的独立文本轨
- **THEN** 系统阻止该章节标记完成且不得用 comment 或 lyrics 元数据静默替代

### Requirement: 完成状态依赖回读校验
系统 SHALL 在原子提交前使用 AVURLAsset 回读临时 M4B，并 MUST 验证文件非空、音频可播放、时长有效、规定元数据、章节项和文本轨存在。

#### Scenario: 产物校验通过
- **WHEN** 临时 M4B 满足全部回读条件
- **THEN** 系统原子移动为最终文件并将章节标记 completed

#### Scenario: 产物校验失败
- **WHEN** 临时 M4B 缺少任一规定轨道或元数据
- **THEN** 系统保留章节为未完成、清理无效临时文件并记录 packaging 错误

### Requirement: 已完成书籍可以导出 ZIP
系统 SHALL 允许用户将已完成书籍导出为 ZIP，归档 SHALL 按章节顺序包含所有 M4B、封面、版本化 `metadata.json` 和 UTF-8 `README.txt`。

#### Scenario: 成功导出整书
- **WHEN** 用户为已完成书籍选择可写目标并确认导出
- **THEN** 系统生成可由 Finder Archive Utility 解压的 ZIP，且章节文件按序号命名

#### Scenario: 未完成书籍尝试导出
- **WHEN** 书籍仍有未完成章节
- **THEN** 系统禁用整书导出并说明需要先完成转换

### Requirement: 导出是可取消且原子的
系统 SHALL 在目标目录使用隐藏临时归档写入，SHALL 展示确定进度并允许取消，只有中央目录和内容校验通过后才原子提交最终 ZIP。

#### Scenario: 用户取消导出
- **WHEN** 用户在 ZIP 写入期间取消
- **THEN** 系统停止导出、删除临时归档且不覆盖任何既有文件

#### Scenario: 目标存在同名文件
- **WHEN** 用户选择已存在的 ZIP 文件名
- **THEN** 系统使用原生保存面板请求覆盖确认而不静默覆盖
