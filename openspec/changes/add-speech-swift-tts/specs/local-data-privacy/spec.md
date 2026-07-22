## MODIFIED Requirements

### Requirement: 书籍处理保持在本机
系统 SHALL 在本机完成 EPUB 解析、章节文本处理、TTS 合成、媒体封装和 ZIP 导出，MUST NOT 将书籍内容、章节正文、音色选择、试听内容、参考声音或生成音频上传到云端；用户明确发起的签名模型包下载是唯一允许的 TTS 相关网络数据流。

#### Scenario: 使用任一本地模型转换书籍
- **WHEN** 用户使用 Apple 系统语音、Kokoro、CosyVoice3 或 Qwen3-TTS 转换一本 EPUB
- **THEN** 所有正文与音频数据只在 App 容器和对应本地运行时之间流动

#### Scenario: 下载安装外部模型
- **WHEN** 用户明确下载 Kokoro、CosyVoice3 或 Qwen3-TTS 模型包
- **THEN** 网络请求只包含获取受信模型文件所需的信息，不包含书籍、作者、文件名、正文、音色设置、试听文本或生成音频

### Requirement: 模型下载网络权限受到限制
系统 SHALL 仅允许模型包管理器访问对应签名清单列出的 HTTPS origin 与重定向来源，MUST NOT 允许 sherpa-onnx、speech-swift 或模型代码发起网络推理或隐式模型下载，并 SHALL 在模型安装后支持完全离线试听与转换。

#### Scenario: 下载来源不在清单
- **WHEN** 模型下载 URL 或重定向的 scheme、host 或资源标识不符合该模型签名清单
- **THEN** 系统拒绝请求且不跟随到未授权来源

#### Scenario: 模型已经安装
- **WHEN** Kokoro、CosyVoice3 或 Qwen3-TTS 已完成安装且网络不可用
- **THEN** 模型菜单、音色目录、试听和书籍转换继续从本地验证资源工作

#### Scenario: speech-swift 尝试隐式下载
- **WHEN** speech-swift 初始化路径缺少本地文件并尝试解析远程仓库或下载资源
- **THEN** App 阻止该操作、将模型标记为损坏或未安装，并只提供由模型包管理器驱动的修复下载

#### Scenario: 记录模型下载日志
- **WHEN** 任一模型下载成功、失败或重试
- **THEN** 日志只包含模型 ID、版本、字节进度、耗时和稳定错误码，不包含用户内容或稳定用户标识
