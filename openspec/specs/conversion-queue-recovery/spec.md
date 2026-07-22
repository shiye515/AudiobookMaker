# conversion-queue-recovery Specification

## Purpose
定义有声书转换任务的持久化排队、并发限制、进度记录、暂停恢复、异常恢复与可诊断重试行为，确保任务在模型和音色资源变化时仍保持可预测、可恢复且结果一致。

## Requirements

### Requirement: 用户可以将书籍加入持久化队列
系统 SHALL 为用户启动的书籍创建持久化 ConversionJob，按 `queueOrdinal` 以 FIFO 顺序调度，并 SHALL 将任务创建时的模型 ID、模型版本和音色 ID 固定到该任务。

#### Scenario: 使用 Kokoro 启动一本就绪书籍
- **WHEN** 用户以已安装 Kokoro 和有效音色对就绪书籍执行“开始转换”
- **THEN** 系统创建包含固定模型 ID、版本和音色 ID 的排队任务并按 FIFO 顺序等待运行

#### Scenario: 多本书排队
- **WHEN** 活跃任务已达到并发上限且用户启动另一书籍
- **THEN** 新任务保持 queued、显示其队列状态且保留创建时的模型与音色三元组

### Requirement: 并发受用户设置与运行时能力共同限制
系统 SHALL 默认最多同时转换 1 本书，SHALL 允许用户将上限设为 1 或 2，且实际并发 MUST 不超过运行时建议上限。

#### Scenario: 用户设置高于运行时上限
- **WHEN** 用户设置并发 2 而运行时建议并发为 1
- **THEN** 系统实际只运行 1 个任务并保持其余任务排队

### Requirement: 章节按顺序转换并持久化进度
系统 SHALL 在同一本书内按章节顺序转换，并 SHALL 以完成字符数占总字符数计算书籍进度，在片段、章节封装和任务完成边界保存 checkpoint。

#### Scenario: 长短章节混合
- **WHEN** 一本书包含字符数差异较大的章节
- **THEN** 总进度按字符权重计算而不是按已完成章节数量平均计算

#### Scenario: 列表与详情显示进度
- **WHEN** 任务进度发生变化
- **THEN** 书籍列表、详情和队列状态基于同一快照显示一致进度

### Requirement: 用户可以暂停和继续任务
系统 SHALL 在暂停时停止创建新请求、取消可安全取消的在途片段、保存 checkpoint，并 SHALL 在继续时验证任务锁定的模型 ID、模型版本和音色 ID，再从首个未验证完成片段恢复。

#### Scenario: 运行时支持即时取消
- **WHEN** 用户暂停正在合成的任务且运行时支持取消
- **THEN** 系统进入 pausing、取消在途请求并最终持久化为 paused

#### Scenario: 运行时不支持即时取消
- **WHEN** 用户暂停任务且运行时声明不支持安全取消
- **THEN** 系统显示“完成当前片段后暂停”并在该片段完成后持久化 paused

#### Scenario: 使用相同模型和音色继续任务
- **WHEN** 用户继续一个 paused 或 interrupted 任务且锁定的模型版本和音色仍可用
- **THEN** 系统从首个未完成 checkpoint 开始并保持原音色

#### Scenario: 锁定的模型版本或音色不可用
- **WHEN** 用户继续任务但其模型版本缺失、损坏或 voice ID 不存在
- **THEN** 系统保持任务暂停并引导恢复相同资源，MUST NOT 静默替换模型或音色

### Requirement: 异常退出后可以断点恢复
系统 SHALL 在启动时将 preparing、running、pausing 和 completing 状态恢复为 interrupted，校验临时文件与最终产物，并 SHALL 不自动启动高负载推理。

#### Scenario: App 在章节完成后、数据库提交前终止
- **WHEN** 启动恢复发现有效且哈希匹配的最终 M4B 但章节未标记完成
- **THEN** 系统回读校验产物并补记章节完成状态而不重新合成

#### Scenario: App 在片段合成中终止
- **WHEN** 启动恢复发现不可验证的 partial 文件
- **THEN** 系统清理该 partial、保留更早 checkpoint 并提示任务可继续

### Requirement: 失败重试是有限且可诊断的
系统 SHALL 对瞬时错误最多自动重试 2 次并采用退避，SHALL 对模型、数据和产物校验错误立即失败，并 SHALL 向用户提供重试或查看详情操作。

#### Scenario: 连续瞬时超时
- **WHEN** 同一片段连续发生可重试超时
- **THEN** 系统退避重试且在达到上限后将任务标记失败

#### Scenario: 输入音频无效
- **WHEN** 运行时返回无法解析的音频
- **THEN** 系统不进入封装阶段并显示稳定的 invalidAudio 错误
