<p align="center">
  <img src="docs/app-icon-transparent.png" width="128" alt="AudiobookMaker 图标">
</p>

<h1 align="center">AudiobookMaker</h1>

<p align="center">
  把 EPUB 变成带章节、封面和完整元数据的 M4B 有声书，全程在 Mac 本地完成。
  <br>
  Turn EPUB books into chaptered, metadata-rich M4B audiobooks entirely on your Mac.
</p>

<p align="center">
  <a href="https://github.com/shiye515/AudiobookMaker/releases/latest"><img src="https://img.shields.io/github/v/release/shiye515/AudiobookMaker?style=flat-square" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square&logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <strong>离线语音合成 · 单文件 M4B · Apple 芯片与 Intel 通用</strong>
</p>

![AudiobookMaker 界面预览](docs/design-reference.svg)

## 为什么选择 AudiobookMaker

- **真正的 M4B 有声书**：导出一个可直接加入 Apple Books 等播放器的 `.m4b` 文件，而不是音频文件压缩包。
- **章节导航**：把 EPUB 章节写入音频时间线，可在播放器中快速跳转。
- **封面与元数据**：保留封面，并写入标题、作者、旁白者、类型和出版日期。
- **本地 AI 音色**：支持基于 sherpa-onnx 的 Kokoro 本地语音合成，也可使用 macOS 系统语音。
- **可暂停、可恢复**：显示章节转换进度，长篇书籍可暂停后继续处理。
- **隐私优先**：书籍解析、语音合成和 M4B 封装都在本机完成，书籍内容不会上传。

播放器负责记忆收听位置、跨设备同步和不变调变速播放；导出的标准 M4B 文件可利用兼容播放器提供的这些能力。

## 下载与使用

1. 前往 [Releases](https://github.com/shiye515/AudiobookMaker/releases/latest) 下载 macOS 通用版本。
2. 解压后把 `AudiobookMaker.app` 拖入“应用程序”。
3. 启动应用，导入 EPUB，选择音色并开始转换。
4. 转换完成后导出单个 M4B 文件。

Release 应用使用 Developer ID Application 证书签名、启用 Hardened Runtime，并通过 Apple 公证；下载后可按普通 macOS 应用直接打开。你也可以直接从源码自行构建。

### 系统要求

- macOS 26.0 或更高版本
- Apple 芯片或 Intel Mac（Release 提供 Universal 2 应用）
- Kokoro 模型需要由用户在应用内主动下载；模型权重不包含在仓库和安装包中

## 工作流程

```text
EPUB → 安全解析章节 → 本地语音合成 → 合并音频 → 写入章节/封面/元数据 → M4B
```

应用会限制 EPUB 解压规模并校验下载模型的完整性；Kokoro 推理通过随应用分发的 Universal 2 sherpa-onnx 与 ONNX Runtime 动态库在本机运行。

## 从源码构建

需要 Xcode 26 或兼容版本：

```bash
git clone https://github.com/shiye515/AudiobookMaker.git
cd AudiobookMaker
open AudiobookMaker.xcodeproj
```

在 Xcode 中选择 `AudiobookMaker` scheme。真机签名构建时，请在 Signing & Capabilities 中选择你自己的开发团队；仅进行本地无签名编译时也可以运行：

```bash
xcodebuild build \
  -project AudiobookMaker.xcodeproj \
  -scheme AudiobookMaker \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

项目主要模块：

- `Services/EPUB`：EPUB 校验、解压、章节与元数据解析
- `Services/TTS`：Apple Speech 与 Kokoro/sherpa-onnx 合成后端
- `Services/Export`：M4B 音频、章节、封面及元数据写入
- `Services/Persistence`：书库、任务状态与断点恢复

开发、运行时分发和验收说明见 [`docs/`](docs/)。

## 隐私与第三方组件

AudiobookMaker 不收集书籍内容或使用数据。仅当用户主动下载语音模型时才需要网络连接，详情见[隐私说明](docs/privacy.md)。

项目分发的 sherpa-onnx、ONNX Runtime 以及外部模型资源各自适用其原始许可证，详见[第三方软件声明](docs/third-party-notices.md)与 [SBOM](docs/sbom.md)。

## 参与贡献

欢迎提交 Issue、功能建议和 Pull Request。报告问题时，请附上 macOS 版本、Mac 芯片类型、可复现步骤和已脱敏的相关日志；请勿上传受版权保护的书籍或模型文件。

## License

AudiobookMaker 的原创代码以 [MIT License](LICENSE) 开源。第三方组件及模型仍遵循各自的许可证。
