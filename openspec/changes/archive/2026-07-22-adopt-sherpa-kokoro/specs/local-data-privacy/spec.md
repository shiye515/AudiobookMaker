## MODIFIED Requirements

### Requirement: 书籍处理保持在本机
系统 SHALL 在本机完成 EPUB 解析、章节文本处理、TTS 合成、媒体封装和 ZIP 导出，MUST NOT 将书籍内容、章节正文、音色选择、试听内容或生成音频上传到云端；模型包下载是唯一允许的 TTS 相关网络数据流。

#### Scenario: 完整转换一本书
- **WHEN** 用户导入并使用 Kokoro 转换一本 EPUB
- **THEN** 所有正文与音频数据只在 App 容器和本地 sherpa-onnx 运行时之间流动

#### Scenario: 下载安装 Kokoro
- **WHEN** 用户明确下载 Kokoro 模型包
- **THEN** 网络请求只包含获取受信模型文件所需的信息，不包含书籍、作者、文件名、正文、音色设置或生成音频

## ADDED Requirements

### Requirement: 模型下载网络权限受到限制
系统 SHALL 仅允许模型包管理器访问签名清单列出的 HTTPS 来源，MUST NOT 允许本地合成运行时发起网络推理，并 SHALL 在模型安装后支持完全离线试听与转换。

#### Scenario: 下载来源不在清单
- **WHEN** 模型下载 URL 的 scheme、host 或资源标识不符合签名清单
- **THEN** 系统拒绝请求且不跟随到未授权来源的重定向

#### Scenario: 模型已经安装
- **WHEN** Kokoro 已完成安装且网络不可用
- **THEN** 模型菜单、音色目录、试听和书籍转换继续从本地资源工作

#### Scenario: 记录模型下载日志
- **WHEN** 下载成功、失败或重试
- **THEN** 日志只包含模型 ID、版本、字节进度、耗时和稳定错误码，不包含用户内容或稳定用户标识
