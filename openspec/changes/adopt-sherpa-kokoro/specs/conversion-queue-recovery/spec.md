## MODIFIED Requirements

### Requirement: 用户可以将书籍加入持久化队列
系统 SHALL 为用户启动的书籍创建持久化 ConversionJob，按 `queueOrdinal` 以 FIFO 顺序调度，并 SHALL 将任务创建时的模型 ID、模型版本和音色 ID 固定到该任务。

#### Scenario: 使用 Kokoro 启动一本就绪书籍
- **WHEN** 用户以已安装 Kokoro 和有效音色对就绪书籍执行“开始转换”
- **THEN** 系统创建包含固定模型 ID、版本和音色 ID 的排队任务并按 FIFO 顺序等待运行

#### Scenario: 多本书排队
- **WHEN** 活跃任务已达到并发上限且用户启动另一书籍
- **THEN** 新任务保持 queued、显示其队列状态且保留创建时的模型与音色三元组

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
