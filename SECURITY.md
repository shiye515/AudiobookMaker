# Security Policy

## Supported versions

本项目以 `main` 分支为唯一支持线；不维护旧 release 分支的安全补丁。

## Reporting a vulnerability

请**不要**在公开 GitHub Issue 中披露可被利用的安全问题。

请通过以下方式之一私下报告：

1. GitHub 仓库的 **Security → Report a vulnerability**（若已启用 Private Vulnerability Reporting）
2. 向仓库维护者发送邮件 / 私信（以 GitHub Profile 公开的联系方式为准）

请尽量包含：

- 影响版本或 commit
- 复现步骤或最小样例（如恶意 EPUB）
- 预期与实际行为
- 已知缓解方式（如有）

我们会在合理时间内确认收悉并反馈处理进展。修复落地后会在变更说明中致谢（除非你希望匿名）。

## 范围说明

- **应用代码**（解析、导出、UI、本地存储路径）在报告范围内。
- **模型权重 / 第三方上游**（speech-swift、MLX、ffmpeg、Hugging Face 模型）请优先报给对应上游；若问题只在本应用的集成方式下触发，仍欢迎告知我们。
- 本应用默认**不开启 App Sandbox**，面向本机个人使用；在不受信任环境运行或处理不可信 EPUB 时请自行评估风险。
