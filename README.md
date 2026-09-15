# abm / AudiobookMaker

**Audiobook Maker** — 把 EPUB / 文本变成本地有声书的 macOS 应用。

导入电子书 → 按目录**节级**拆章节 → 用 **CosyVoice3** 在本机批量合成 → 导出带章节的 **M4B**。

[![CI](https://github.com/shiye515/AudiobookMaker/actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)](#系统要求)
[![Chip](https://img.shields.io/badge/CPU-Apple%20Silicon-lightgrey)](#系统要求)

> SwiftUI · 本地推理 · 不上传你的书

---

## 为什么选 abm

| | |
|---|---|
| **真正可用的章节** | 按 EPUB 目录最小节切分，支持同文件锚点；脏目录（Calibre 错位 NCX）会以正文为准纠正标题 |
| **全程本地** | CosyVoice3 + MLX 在 Apple Silicon 上推理，正文与音频不出机器 |
| **像做书，不像跑脚本** | 书库、章节队列、断点续传、试听播放条、一键导出 |
| **导出能进 Books** | M4B：AAC + 章节标记 + 封面 + 元数据 |

## 功能一览

- **EPUB 导入**：封面 / 作者 / 字数；节级章节与「卷 · 章 · 节」层级标题  
- **批量合成**：全书入队、暂停/继续、分段断点崩溃可续  
- **音色**：内置参考样本 + 零样本克隆；可按书设置默认音色  
- **导出**：整书 M4B、分章 M4A、WAV；进度可取消  
- **快速单文本**：不建书也能合成一段话  

## 系统要求

- Apple Silicon Mac（M1 及以后）  
- macOS 15+（以 Xcode 工程部署目标为准）  
- 建议 16GB+ 内存；首次下载模型约 2GB+  

## 快速开始

```bash
git clone https://github.com/shiye515/AudiobookMaker.git
cd abm
open abm.xcodeproj
```

1. 等待 Swift Package 解析完成  
2. `⌘R` 运行  
3. 应用内点「初始化模型」，按提示下载权重（仅一次）  
4. 拖入 EPUB 或点「+ 导入」→「一键生成全书」→ 导出 M4B  

更细的步骤见 [docs/FAQ.md](docs/FAQ.md)。

**从源码构建（命令行）**

```bash
xcodebuild -project abm.xcodeproj -scheme abm -configuration Debug \
  -destination 'platform=macOS' build
```

M4B 导出需要先构建内置 ffmpeg（仓库不提交二进制）：

```bash
scripts/build-ffmpeg.sh
```

## 参与开发

欢迎 PR、Issue、文档与夹具贡献——从这些入口最容易上手：

1. 报一本「章节拆错」的 EPUB（可匿名化）并贴上  
   `abm --verify-epub-split book.epub` 输出  
2. 补 `docs/screenshots/` 演示图  
3. 改进 FAQ / 界面文案  
4. 在 `openspec/` 里提行为变更提案  

- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md)  
- 行为准则：[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)  
- 安全披露：[SECURITY.md](SECURITY.md)  
- 路线与历史决策：`docs/HANDOFF.md`、`openspec/`  

有想法但不想开 Issue？也欢迎直接开 Draft PR。

## 仓库结构

```
abm/                  应用（SwiftUI / Core / Services）
abm.xcodeproj/        Xcode 工程
Vendor/speech-swift/  本地 TTS 框架（含 Archive 用 float32 补丁）
scripts/              ffmpeg 构建、Archive、EPUB 解析校验
openspec/             规格与变更提案
docs/                 FAQ、发布、截图、技术文档
```

## 许可与第三方

应用代码 [MIT](LICENSE)。依赖与**模型权重**许可见 [NOTICE](NOTICE)。  
使用克隆音色时，请确保你有权使用对应参考音频。

## 免责声明

软件按“原样”提供。请遵守当地法律与版权，仅合成你有权使用的文本与声音。
