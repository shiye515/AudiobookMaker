# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格；版本号在打 tag / 发布 Release 时维护。

## [Unreleased]

### Added

- 开源仓库基础文件：MIT `LICENSE`、`NOTICE`、`CONTRIBUTING`、`SECURITY`、`CODE_OF_CONDUCT`
- GitHub Issue / PR 模板与 macOS 构建 CI
- EPUB 节级章节拆分：同文件锚点切分、层级链 `parentPath` / `fullTitle`、Calibre 脏目录回退
- 书库「正在生成」筛选纳入排队中书籍
- 内置 ffmpeg Hardened Runtime 签名构建阶段（公证/上传友好）

### Changed

- speech-swift 本地化至 `Vendor/speech-swift`（CamPlusPlus 使用 float32，修复 Archive x86_64）
- 导出章节名使用全路径；播放条仍显示叶子标题

### Fixed

- 真实 EPUB（NCX 与正文错位）章节标题对不上正文的问题
