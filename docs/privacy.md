# 隐私说明

AudiobookMaker 的 EPUB 解析、文本分片、语音合成、M4B 封装与导出全部在 Mac 本机完成。书籍正文、书名、作者、封面、生成音频和用户选择的音色不会上传到任何服务器。

应用只在用户点击“下载模型”后联网获取 CosyVoice3 或 Qwen3-TTS 模型文件；Apple 系统语音无需下载。下载请求使用签名内置清单中的固定 HTTPS 地址，只携带通用的 `AudiobookMaker/1 ModelInstaller` User-Agent，不附带书籍正文、文件名、试听文本、音色设置、生成音频或用户内容。重定向仅允许清单声明的 Hugging Face/CDN 精确主机，下载后会校验逐文件大小和 SHA-256，并进行安全安装与离线运行时探测。

模型保存在 App 的 Application Support 版本化目录中，不随 App 安装包分发。speech-swift 被强制从已验证的本地目录以 offline 模式加载；缺少 tokenizer、codec 或权重会进入损坏/修复状态，不会隐式联网。模型安装完成后，音色试听和全书转换均可离线运行。应用日志不会记录章节全文或试听文本；书名、作者和文件路径按私密字段处理，性能记录只使用 request ID、耗时、帧数与稳定错误码。
