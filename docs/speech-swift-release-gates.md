# speech-swift / MLX Apple Silicon 发布门禁

## 用户行为

Apple 系统语音无需下载。CosyVoice3 与 Qwen3-TTS 只在用户明确点击下载后联网；安装完成后，音色列表、试听和转换均从 App 管理的已验证目录离线运行。高内存运行时的有效并发为用户配置、运行时建议和模型安全上限三者最小值。

取消 MLX/Metal 推理时，当前 kernel 可能无法立即停止。运行时不再提交后续片段，并在安全边界丢弃晚到结果；取消后的音频不会写入 checkpoint。

## 构建与归档

1. 使用 Apple Silicon Mac、完整 Xcode 26 和 Metal Toolchain。
2. 复验 `Package.resolved` 与 `Vendor/speech-swift/UPSTREAM.md` 中的固定 revision。
3. 运行 `Tools/archive-apple-silicon.sh` 生成 Release archive。
4. `Tools/verify-release-artifacts.sh` 必须确认全部 Mach-O 仅含 arm64，链接图和 bundle 不含已移除运行时或模型权重。
5. 使用 Developer ID Application 签名，验证 hardened runtime，提交公证并 staple；最后运行 `codesign --verify --deep --strict`、`spctl --assess --type execute` 和 `stapler validate`。

## 真实模型验收

在 `docs/apple-silicon-performance.md` 固定的 Mac16,11 / 24 GiB / macOS 26.5.2 / Release 环境分别运行 CosyVoice3 与 Qwen3-TTS：

- 精确 snapshot 下载、取消/resume、哈希与 receipt
- 冷/热加载、首音频、连续片段、模型切换与内存压力卸载
- 固定试听样本、450 字长片段、代表性真实 EPUB 子集
- 暂停、进程重启、同 model/version/voice 恢复
- 断网重启、损坏模型修复、单文件 M4B 导出
- 峰值 RSS、卸载后 RSS、RTF、失败率与 App/模型体积

`metrics.json` 必须是 schema v2，并通过 `Tools/compare-performance-baseline.py`。设备、模型、语料或样本不完整时不得更新基线。

人工听感使用 `docs/speech-swift-listening-acceptance.md` 的固定数字、日期、专名、中英混排和章节边界样本。自动音频结构校验不代替听感签字。

## 当前状态（2026-07-23）

- arm64 Release build 与依赖纯净性门禁：通过。
- 迁移、平台、安装、运行时、并发、切片和取消相关单元测试：通过。
- 历史 2026-07-22 两模型结果已保存在 `docs/apple-silicon-performance-baseline.json`，但缺少热加载字段，尚不是可批准的完整回归基线。
- Development-signed UI 自动化、Developer ID 公证候选和完整固定环境性能复跑：待执行。

不得使用历史 Universal 2 archive、Debug App 或注入式 fake session 冒充最终发布证据。
