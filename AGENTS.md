# AGENTS.md

AI 协作规范。所有 AI 代理（ZCode、Claude Code 等）在本仓库工作时必须遵守以下规则。

## 项目概览

**abm** — CosyVoice TTS macOS 原生应用。用 SwiftUI 构建，通过 CosyVoice3（本地推理，soniqo/speech-swift 框架，SPM 产品 `CosyVoiceTTS`）把文本/EPUB 转成语音，支持书库管理、批量合成、音频导出。

- 语言/框架：Swift 6 + SwiftUI（macOS）
- 工程：`abm.xcodeproj`（Xcode 16+）
- 技术文档：`docs/cosyvoice-tts-app.md`（核心技术文档）、`docs/HANDOFF.md`（交接文档）
- 工作流：OpenSpec（spec-driven），变更提案在 `openspec/changes/`，主规格在 `openspec/specs/`

## Git 规则（必须遵守）

**禁止自动暂存文件。**

- **绝不执行** `git add`、`git add -A`、`git add .`、`git stage`、`git commit -a` 等任何将文件加入暂存区的命令。
- 修改、创建、删除文件后**只修改工作区**，不要自动暂存、不要自动提交。
- 暂存与提交由用户自己决定和执行；如用户明确要求提交，先展示 `git status` 与变更内容，等用户确认后再操作。
- 同理，禁止自动 `git push`、`git stash`、`git checkout --`（丢弃变更）等破坏性或影响用户工作区状态的命令。

## 工作约定

- 沟通与代码注释使用中文；代码命名遵循 Swift 惯例（英文）。
- 实现新功能前，先查看 `openspec/specs/` 与 `openspec/changes/` 中对应规格；规格驱动开发，先提案后实现。
- 修改后如涉及规格变更，同步更新 OpenSpec 变更目录下的 delta spec。
- 不要重新调研已定技术路线（见 `docs/HANDOFF.md` 第 2 节）。
