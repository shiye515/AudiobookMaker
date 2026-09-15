# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格。

## [1.0.2] — 2026-09-15

第二个公开版本。叙述见 [docs/RELEASE_NOTES_v1.0.2.md](docs/RELEASE_NOTES_v1.0.2.md)。

### Added

- 节级 EPUB 章节拆分：同文件锚点、层级标题链、无可靠锚点时整文件回退  
- `--verify-epub-split` 无头解析诊断与 `scripts/` 夹具校验  
- 书库「正在生成」纳入排队书籍；卡片「排队中」状态  
- 开源协作文档：LICENSE / NOTICE / CONTRIBUTING / SECURITY / CODE_OF_CONDUCT  
- GitHub Issue、PR 模板与 macOS CI  
- FAQ、Release notes、界面与 iPhone 听书截图  

### Changed

- 导出章节名使用层级全路径；播放条显示叶子标题  
- speech-swift 本地化至 `Vendor/speech-swift`（CamPlusPlus float32，修复 Archive x86_64 / GUI Archive）  
- 内置 ffmpeg 构建阶段 Hardened Runtime 签名  

### Fixed

- NCX 与正文错位的 EPUB 章节标题对不上内容  
- Archive / 公证时嵌套 `ffmpeg` 缺少 Hardened Runtime  

## [1.0.0]

见 Git 标签 [v1.0.0](https://github.com/shiye515/AudiobookMaker/releases/tag/v1.0.0)。

## [Unreleased]

（无）
