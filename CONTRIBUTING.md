# Contributing to abm

感谢关注本项目。

## 开发环境

- macOS 15+（工程部署目标以 `MACOSX_DEPLOYMENT_TARGET` 为准）
- Xcode 16+
- Apple Silicon（MLX 推理依赖；x86_64 不作为运行目标）

## 开始

```bash
git clone <this-repo>
cd abm
open abm.xcodeproj
```

首次解析 SPM 依赖后，在 Xcode 中 `⌘R` 运行。模型权重不随仓库分发，应用内首次初始化会从 Hugging Face 下载（体积约数 GB，请预留磁盘与内存）。

## 代码约定

- 沟通与注释使用中文；标识符遵循 Swift 惯例（英文）
- 功能变更走 OpenSpec：提案放在 `openspec/changes/<change-id>/`，实现后同步 delta spec
- 不要自动 `git add` / `git commit` / `git push`，由维护者决定提交时机
- 架构与踩坑记录见 `docs/HANDOFF.md` 与 `docs/cosyvoice-tts-app.md`

## 本地脚本

| 脚本 | 用途 |
|------|------|
| `scripts/build-ffmpeg.sh` | 构建应用内极简 ffmpeg（导出用） |
| `scripts/archive-app.sh` | CLI Archive（GUI Product→Archive 亦可用） |
| `scripts/make_epub_fixtures.py` + `scripts/verify_epub_split.sh` | EPUB 章节解析夹具校验 |
| `abm --verify-epub-split <path.epub\|fixturesDir>` | 无头解析诊断 |

## 测试

仓库当前无独立 XCTest target。涉及 EPUB 解析的改动请至少跑通 `scripts/verify_epub_split.sh`，并附上真实书或夹具的章节数/标题抽样。

## Pull Request

1. 说明动机与行为变化（用户可见则写清迁移/重导影响）
2. 列出验证方式（构建命令、夹具输出、真机步骤）
3. 若改规格，附带 `openspec/` 目录下对应 delta
4. 保持 diff 聚焦，避免顺手重构无关文件

## 许可证

贡献即表示同意以 MIT 许可证授权本仓库代码（见 `LICENSE`）。第三方依赖与模型权重许可见 `NOTICE`。
